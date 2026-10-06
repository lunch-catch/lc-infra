/*
 * Ubuntu 24.04 LTS.
 * t3 와 t3a 는 x86, t4g 는 ARM 이라 이미지를 따로 찾는다.
 */
data "aws_ami" "ubuntu_x86" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "aws_ami" "ubuntu_arm" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
}

/*
 * 앱과 배치는 같은 jar 를 쓰고 프로필로만 갈린다.
 * 앱에는 batch 가 절대 들어가면 안 된다 (INF-12-07).
 * 들어가면 앱 대수만큼 스케줄러가 함께 돌고, 분산 락이 없어 아무것도 막지 못한다.
 */
locals {
  common_bootstrap = file("${path.module}/templates/common-bootstrap.sh")
  alloy_config     = file("${path.module}/../observability/alloy/config.alloy")

  # 최초 부팅과 재배포가 같은 코드를 쓴다
  refresh_env = templatefile("${path.module}/templates/refresh-env.sh.tftpl", {
    project  = var.project
    region   = var.region
    registry = local.ecr_registry
  })

  # 모니터링도 같은 이유로 갱신 경로가 필요하다. 다만 읽는 값과 쓰는 자리가 달라 별도다
  refresh_monitoring_env = templatefile("${path.module}/templates/refresh-monitoring-env.sh.tftpl", {
    project     = var.project
    region      = var.region
    db_username = var.db_username
  })

  /*
   * ASG 밖 인스턴스용이다. Docker 와 AWS CLI 만 깔고 끝난다.
   * 모니터링은 관측 스택을, 부하 생성은 k6 를 컨테이너로 돌리지만 그것을 올리는 것은 이 스크립트가 아니다.
   */
  standalone_user_data = "#!/bin/bash\n${local.common_bootstrap}"

  /*
   * 부하 생성기다. 커널 튜닝과 k6 설치, 시나리오와 토큰 준비까지 한다.
   *
   * 시나리오는 lc-backend 가 갖는다 (loadtest/). 발급 경로와 상태 코드, 토큰 클레임,
   * 스키마에 묶여 있어 백엔드가 바뀌면 같이 바뀌어야 하는 것들이다.
   * 여기서는 받아 오기만 하고, 레포가 public 이라 토큰 없이 클론한다.
   */
  load_test_user_data = templatefile("${path.module}/templates/load-test-user-data.sh.tftpl", {
    common_bootstrap = local.common_bootstrap
    project          = var.project
    region           = var.region
    github_org       = var.github_org
    backend_repo     = var.github_backend_repo
    alb_dns_name     = aws_lb.main.dns_name
    k6_version       = var.k6_version
    # compose.yaml 의 prom/node-exporter 태그와 같은 값을 쓴다
    node_exporter_version = var.node_exporter_version
  })

  monitoring_user_data = templatefile("${path.module}/templates/monitoring-user-data.sh.tftpl", {
    common_bootstrap = local.common_bootstrap
    project          = var.project
    region           = var.region
    github_org       = var.github_org
    infra_repo       = var.github_infra_repo
    db_username      = var.db_username
    refresh_env      = local.refresh_monitoring_env
  })

  /*
   * 이미지 주소다. aws_ecr_repository.app.repository_url 을 쓰지 않는다.
   *
   * 그 속성은 apply 전까지 모르는 값인데 templatefile() 은 plan 시점에 값을 요구한다.
   * 저장소를 처음 만드는 plan 이 그 자리에서 막힌다.
   *
   * 주소 형식은 AWS 가 정한 것이라 계정과 리전과 이름만 있으면 결정된다. 셋 다 알려진 값이다.
   */
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  app_image    = "${local.ecr_registry}/${var.project}"

  compose_args = {
    project     = var.project
    app_image   = local.app_image
    db_name     = var.db_name
    db_username = var.db_username
  }

  app_user_data = templatefile("${path.module}/templates/app-user-data.sh.tftpl", {
    common_bootstrap = local.common_bootstrap
    project          = var.project
    region           = var.region
    github_org       = var.github_org
    refresh_env      = local.refresh_env
    alloy            = local.alloy_config
    compose          = templatefile("${path.module}/templates/compose.yaml.tftpl", merge(local.compose_args, { profiles = "prod", role = "app" }))
    unit             = templatefile("${path.module}/templates/systemd.service.tftpl", { project = var.project, profiles = "prod" })
  })

  batch_user_data = templatefile("${path.module}/templates/app-user-data.sh.tftpl", {
    common_bootstrap = local.common_bootstrap
    project          = var.project
    region           = var.region
    github_org       = var.github_org
    refresh_env      = local.refresh_env
    alloy            = local.alloy_config
    compose          = templatefile("${path.module}/templates/compose.yaml.tftpl", merge(local.compose_args, { profiles = "prod,batch", role = "batch" }))
    unit             = templatefile("${path.module}/templates/systemd.service.tftpl", { project = var.project, profiles = "prod,batch" })
  })
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-app-"
  image_id      = data.aws_ami.ubuntu_x86.id
  instance_type = var.instance_types["app"]

  iam_instance_profile {
    name = aws_iam_instance_profile.instance["app"].name
  }

  vpc_security_group_ids = [aws_security_group.app.id]
  user_data              = base64encode(local.app_user_data)

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # 토큰을 요구한다. SSRF 로 자격증명이 새는 경로를 막는다.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.project}-app"
      Role = "app"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

/*
 * 트래픽에 따라 2~3 대로 움직인다.
 *
 * min_size 가 2 다. 1 이었을 때는 한산한 구간에서 앱이 단일 장애점이었다. ASG 가 죽은
 * 인스턴스를 다시 만들지만 기동에 4~6분이 걸리고 그동안 서비스가 멈춘다. 자가 치유는
 * 이중화가 아니다. 두 대가 서로 다른 AZ 에 떠 있어야 AZ 하나를 잃어도 버틴다 (2026-09-23).
 *
 * 0 으로 두지 않는 이유는 그대로다. 정책이 스케일 인으로 0 까지 내려 서비스가 사라진다.
 * 세션을 끝낼 때는 stop.sh 가 min 을 0 으로 내린 뒤 desired 를 0 으로 준다.
 *
 * desired_capacity 를 고쳐도 ignore_changes 때문에 이미 있는 ASG 에는 안 먹는다.
 * 실제로 대수를 끌어올리는 것은 min_size 다.
 *
 * max_size 3 이 확장 상한이자 배포 여유를 겸한다. deploy.sh 가 desired + 1 로 신규를 띄우므로,
 * 3 대까지 올라간 상태에서는 배포가 막힌다. 드문 경우이고 스케일 인을 기다리면 풀린다.
 *
 * 4 로 올리지 않는 것은 정한 상한이 3 이기 때문이다 (INF-39). 커넥션이 아니다.
 * 백엔드가 앱 풀을 8 로 낮춘 뒤로 4 대도 예산에 든다. 배포 중 53 이 하드 리밋 60 안이다.
 * 배포 막힘을 풀어야 할 만큼 아프면 4 로 올릴 수 있다는 뜻이다.
 *
 * desired_capacity 는 배포 스크립트와 정책이 조절한다. Terraform 이 되돌리면 배포가 깨진다.
 */
resource "aws_autoscaling_group" "app" {
  name                = "${var.project}-app"
  vpc_zone_identifier = [for s in aws_subnet.private : s.id]

  min_size         = 2
  desired_capacity = 2
  max_size         = 3

  # ELB 헬스체크를 본다. 프로세스는 살아 있는데 응답을 못 하는 경우를 잡는다.
  health_check_type         = "ELB"
  health_check_grace_period = 300

  /*
   * 새로 띄운 인스턴스가 제 몫을 하기까지 ASG 가 기다려 주는 시간이다.
   *
   * 이게 없으면 부팅 중인 대수를 계산에 안 넣어 정책이 같은 부하를 두 번 센다.
   * 1대에서 분당 12000 이 오면 2대로 늘리는데, 신규가 뜨는 4~6분 동안 지표가 그대로라
   * 3분 뒤 재판정에서 ceil(2 x 12000/6000) = 4 가 나온다. max 3 에서 잘려도 한 대를 더 띄운다.
   *
   * 300 은 실측이 아니다. 기동 시간을 아직 안 쟀고(오토스케일링 설계 6.2절 미정),
   * 같은 이유로 잡힌 health_check_grace_period 와 맞춰 둔 값이다.
   * 첫 배포에서 증설부터 healthy 까지를 재고 그 값으로 바꾼다.
   *
   * 길게 잡아서 손해 보는 것은 정당한 추가 확장이 늦어지는 것인데, 상한이 3이라 거의 없다.
   *
   */
  default_instance_warmup = 300

  target_group_arns = [
    aws_lb_target_group.app.arn,
    aws_lb_target_group.liveness.arn,
  ]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }

  /*
   * 인스턴스가 읽을 SSM 값이 먼저 있어야 한다. 근거는 aws_autoscaling_group.batch 에 있다.
   *
   * ASG 는 apply 도중에 인스턴스를 띄우므로 이 순서가 없으면 첫 대수가 값 없이 뜬다.
   * 그 인스턴스는 헬스체크에 실패해 ASG 가 교체하므로 스스로 낫지만, 교체가 도는 동안
   * 배포의 healthy 대기가 헛돈다.
   */
  depends_on = [
    aws_ssm_parameter.current_sha,
    aws_ssm_parameter.db_endpoint,
    aws_ssm_parameter.cache_endpoint,
    aws_ssm_parameter.cdn_domain,
    aws_ssm_parameter.batch_scheduler_enabled,
    aws_ssm_parameter.loki_endpoint,
  ]
}

/*
 * 스케일 인 때 배치가 돌고 있으면 기다린다 (OPS-1-04).
 * heartbeat_timeout 은 배치 최대 실행 시간 + 여유여야 하는데 아직 측정 전이다.
 * 부하 시험 후 실제 값으로 줄인다.
 */
resource "aws_autoscaling_lifecycle_hook" "app_terminating" {
  name                   = "${var.project}-drain"
  autoscaling_group_name = aws_autoscaling_group.app.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  heartbeat_timeout      = 300
  default_result         = "CONTINUE"
}

/*
 * 트래픽으로 앱을 늘린다.
 *
 * 스케일 인을 막지 않는다. 상시 서비스라 부하가 빠지면 내려가는 것이 맞다.
 *
 * 이 정책이 CloudWatch 알람 2개를 자동으로 만든다. alarms.tf 와 합친 수는 alarms.tf 머리에 있다.
 */
resource "aws_autoscaling_policy" "app_requests" {
  name                   = "${var.project}-app-requests"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }

    target_value = var.app_target_requests_per_instance
  }
}

/*
 * 배치 서버다. 앱과 같은 jar 를 prod,batch 프로필로 띄운다. ALB 에 붙지 않는다.
 *
 * AMI 가 x86 인 것은 앱과 같은 컨테이너 이미지를 받기 때문이다.
 * 빌드가 러너(x86_64)에서 단일 아키텍처로 나오므로 앱이 x86 인 한 배치도 x86 이어야 한다.
 * arm 으로 두었을 때 컨테이너가 exec format error 로 계속 재시작했다.
 */
resource "aws_launch_template" "batch" {
  name_prefix   = "${var.project}-batch-"
  image_id      = data.aws_ami.ubuntu_x86.id
  instance_type = var.instance_types["batch"]

  iam_instance_profile {
    name = aws_iam_instance_profile.instance["batch"].name
  }

  vpc_security_group_ids = [aws_security_group.batch.id]
  user_data              = base64encode(local.batch_user_data)

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.project}-batch"
      Role = "batch"
    }
  }

  /*
   * AMI 변경을 무시한다.
   *
   * 아래 ASG 는 템플릿 버전이 바뀌면 인스턴스를 교체한다. 그런데 image_id 는 most_recent 라
   * Canonical 이 새 AMI 를 올릴 때마다 무관한 apply 가 새 버전을 만들어 배치를 갈아엎는다.
   * 돌던 작업은 다른 배치가 이어받지만, 우리가 고친 것이 없는데 교체가 일어날 이유가 없다.
   * 템플릿(user-data)을 고친 교체는 의도한 것이라 그대로 일어난다.
   */
  lifecycle {
    create_before_destroy = true
    ignore_changes        = [image_id]
  }
}

/*
 * 두 대를 AZ 마다 하나씩 둔다. 둘 다 스케줄러를 켠 액티브-액티브다 (백엔드 배치 운영 문서 2장).
 * 한 대만 두면 00:00 에 장애가 났을 때 사람이 넘겨야 한다. 같은 작업을 동시에 시도해도
 * batch_execution_log 의 유일 제약이 한쪽만 통과시키고, 멈춘 쪽의 작업은 2분 뒤 다른 쪽이 이어받는다.
 *
 * ASG 에 두는 것은 자가 치유 때문이다. 처음에는 "프로세스는 항상 하나" 라 롤링 대상이 아니라는
 * 이유로 단독 인스턴스였는데, 액티브-액티브가 되면서 그 근거가 사라졌다. 단독 인스턴스는
 * 종료되거나 AZ 를 잃으면 사람이 apply 할 때까지 돌아오지 않는다. ASG 는 남은 AZ 에 다시 띄운다.
 *
 * 대수는 고정이다. 스케일링 정책이 없다. 배치는 부하에 따라 늘릴 일이 없고, 늘려도 점유 경쟁만 는다.
 * 세션을 끝낼 때는 stop.sh 가 min 과 desired 를 0 으로 내리고 start.sh 가 2 로 되돌린다.
 */
resource "aws_autoscaling_group" "batch" {
  name                = "${var.project}-batch"
  vpc_zone_identifier = [for s in aws_subnet.private : s.id]

  min_size         = 2
  desired_capacity = 2
  max_size         = 2

  /*
   * EC2 상태 검사만 본다. ALB 대상이 아니라 ELB 헬스체크가 없다.
   * 컨테이너가 죽은 것은 Docker 의 restart 가 되살리고, 반복되면 ContainerRestartLoop 이 운다.
   */
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.batch.id
    version = aws_launch_template.batch.latest_version
  }

  /*
   * 템플릿을 고치면 한 대씩 교체한다. 버전을 $Latest 가 아니라 숫자로 걸어야 Terraform 이
   * 바뀐 것을 알고 교체를 시작한다.
   *
   * 50% 는 두 대 중 한 대다. 한 대가 교체되는 동안 다른 한 대가 작업을 맡는다.
   * 둘을 한꺼번에 내리면 그 사이 00:00 묶음이 비고 이어받을 서버도 없다.
   */
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 180
    }
  }

  # CloudWatch 의 batch-capacity 알람이 본다. 1분 단위 그룹 지표는 무료다.
  enabled_metrics = ["GroupInServiceInstances"]

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = true
  }

  # stop.sh 와 start.sh 가 세션마다 바꾼다. apply 가 되돌리면 세션 중에 배치가 뜬다.
  lifecycle {
    ignore_changes = [desired_capacity, min_size]
  }

  /*
   * 인스턴스가 읽을 SSM 값이 먼저 있어야 한다.
   *
   * Terraform 은 user-data 안의 문자열을 읽지 않으므로 이 의존을 스스로 세우지 못한다.
   * 2026-09-26 에 배치가 RDS 보다 16분 먼저 떠서 db-endpoint 가 없었고, refresh-env 가
   * 거기서 죽어 systemd 유닛조차 안 쓰였다. 인스턴스는 살아 있는데 아무것도 안 돌았다.
   *
   * refresh-env 에도 대기를 넣었지만 그것은 나중 기동을 위한 안전망이다. apply 를 10분
   * 기다리게 둘 이유가 없으므로 순서는 여기서 못 박는다.
   */
  depends_on = [
    aws_ssm_parameter.current_sha,
    aws_ssm_parameter.db_endpoint,
    aws_ssm_parameter.cache_endpoint,
    aws_ssm_parameter.cdn_domain,
    aws_ssm_parameter.batch_scheduler_enabled,
    aws_ssm_parameter.loki_endpoint,
  ]
}

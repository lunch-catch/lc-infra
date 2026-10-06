/*
 * ASG 밖의 인스턴스들이다.
 *
 * 모니터링은 ASG 에 넣지 않는다 (INF-24).
 * desired 0 이 EBS 까지 지워 Prometheus 와 Loki 데이터가 사라진다.
 *
 * 배치는 여기 없다. 2026-10-06 에 ASG 고정 2대로 옮겼다 (INF-41). compute.tf 의 aws_autoscaling_group.batch 를 보라.
 */

resource "aws_instance" "monitoring" {
  ami           = data.aws_ami.ubuntu_arm.id
  instance_type = var.instance_types["monitoring"]

  /*
   * 자리가 DuckDNS 사용 여부로 갈린다.
   *
   * Caddy 가 Let's Encrypt 에서 인증서를 받으려면 80 으로 들어오는 검증 요청을 받아야 한다
   * (HTTP-01). 사설 서브넷에는 들어올 길이 없어 발급이 반복 실패하고, Let's Encrypt 는
   * 실패에도 한도가 있어 금방 막힌다. 그래서 둘을 함께 켤 수 없다.
   *
   * 도메인을 사면 ALB + OIDC 경로(has_grafana)가 열리고, 그때는 사설이어도 볼 수 있다.
   * 그 전까지 사설 상태에서 보는 방법은 SSM 포트 포워딩이다 (observability/README.md).
   */
  subnet_id              = local.has_duckdns ? aws_subnet.public["a"].id : aws_subnet.private["a"].id
  vpc_security_group_ids = [aws_security_group.mon.id]
  iam_instance_profile   = aws_iam_instance_profile.instance["monitoring"].name

  # 관측 데이터가 쌓인다. 앱보다 크게 잡는다.
  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  /*
   * observability/ 를 클론해 스택을 올린다.
   * 설정을 Terraform 이 아니라 Git 이 갖는 이유는 INF-32 와 OPS-2-18 에 있다.
   * 임계값을 고칠 때마다 apply 를 하지 않기 위해서다.
   */
  user_data_base64 = base64encode(local.monitoring_user_data)

  tags = {
    Name = "${var.project}-monitoring"
    Role = "monitoring"
  }

  /*
   * 모니터링이 읽을 SSM 값이 먼저 있어야 한다. 근거는 compute.tf 의 aws_autoscaling_group.batch 에 있다.
   *
   * 이쪽은 user-data 에 set -e 가 없어 2026-09-26 에 ParameterNotFound 를 두 번 맞고도 떴다.
   * 죽지 않았을 뿐이고 값이 빈 채로 뜬 것이라 오히려 찾기 어렵다. 그 둘이 db-endpoint 와
   * cache-endpoint 이고, mysqld-exporter 와 redis-exporter 가 그 값으로 대상을 잡는다.
   *
   * loki-endpoint 와 prometheus-endpoint 는 넣지 않는다. 그 둘의 값이 이 인스턴스의 private_ip
   * 라서 넣으면 순환이 된다. 다른 인스턴스가 모니터링을 찾는 값이고 모니터링 자신은 안 읽는다.
   */
  depends_on = [
    aws_ssm_parameter.db_endpoint,
    aws_ssm_parameter.cache_endpoint,
    aws_ssm_parameter.grafana_root_url,
    aws_ssm_parameter.grafana_auth_proxy,
    aws_ssm_parameter.duckdns_hostname,
  ]

  lifecycle {
    # EBS 에 관측 데이터가 있다. 태우면 되돌릴 수 없다.
    prevent_destroy = true

    /*
     * AMI 가 바뀌어도 이 인스턴스를 갈아엎지 않는다.
     *
     * data.aws_ami 가 most_recent 라 Canonical 이 새 Ubuntu 를 올리면 교체 대상이 되는데,
     * 위 prevent_destroy 가 그것을 거부해 **모든 apply 가 그 자리에서 죽는다.**
     * 무관한 변경 하나를 넣으려 해도 못 넣게 된다. 실제로 그렇게 막혔다 (2026-09-23).
     *
     * 이 인스턴스는 ASG 밖이라 AMI 갱신이 자동으로 필요하지 않다. 커널을 올려야 하면
     * 사람이 판단해서 replace 한다. 그때는 관측 데이터를 먼저 챙긴다.
     */
    ignore_changes = [ami]
  }
}

/*
 * 시험 시간에만 기동한다 (월 약 40시간).
 * 상시 가동 전제의 예외라 count 로 끈다.
 */
resource "aws_instance" "load_test" {
  count = var.load_test_enabled ? 1 : 0

  ami                    = data.aws_ami.ubuntu_x86.id
  instance_type          = var.instance_types["load_test"]
  subnet_id              = aws_subnet.public["a"].id
  vpc_security_group_ids = [aws_security_group.loadtest.id]
  iam_instance_profile   = aws_iam_instance_profile.instance["loadtest"].name
  user_data_base64       = base64encode(local.load_test_user_data)

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = "${var.project}-load-test"
    Role = "load-test"
  }
}

/*
 * DuckDNS 는 A 레코드만 받는다. stop.sh 로 인스턴스를 내렸다 올리면 공인 IP 가 바뀌므로
 * 그때마다 DuckDNS 를 손으로 갱신해야 한다. 주소를 고정해 그 일을 없앤다.
 *
 * 인스턴스가 켜져 있는 동안에는 원래 내던 공인 IPv4 요금을 대신 낸다.
 * 멈춰 둔 시간만큼은 EIP 요금이 따로 붙는다. 시간당 0.005 USD 수준이다.
 */
resource "aws_eip" "monitoring" {
  count = local.has_duckdns ? 1 : 0

  instance = aws_instance.monitoring.id
  domain   = "vpc"

  tags = {
    Name = "${var.project}-monitoring"
  }
}

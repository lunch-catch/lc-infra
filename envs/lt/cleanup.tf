/*
 * 팀원 부하 시험 환경의 자동 정리다 (scripts/member-env.sh, #11).
 * 부하 시험 루트(envs/lt)에만 있다. 운영(envs/prod)에는 들어가지 않는다.
 *
 * 띄운 사람이 down 을 잊어도 member_expires_at 에 돈이 드는 것을 AWS 가 스스로 지운다.
 * 노트북을 닫아도 돈다. EventBridge Scheduler 가 AWS API 를 직접 부르므로 Lambda 코드가 없다.
 *
 * 지우는 것: 앱과 배치 ASG(0대로), 모니터링과 부하 생성기, NAT, ALB, 캐시, RDS, NAT 고정 IP.
 * 남는 것: VPC, 보안 그룹, S3, CloudFront, SSM. 켜 두어도 돈이 거의 들지 않는다.
 * 남은 것은 다음 down 이 지운다. 이미 지워진 자원은 Terraform 이 새로 고침에서 알아서 뺀다.
 *
 * up 을 다시 부르면 member_expires_at 이 다시 계산되어 정리 시각이 뒤로 밀린다.
 */

variable "member_expires_at" {
  description = "자동 정리 시각. UTC, 예: 2026-10-20T10:00:00"
  type        = string
}

locals {
  member_cleanup_at = "at(${var.member_expires_at})"

  # NAT 를 지운 뒤 고정 IP 를 놓는다. NAT 가 지워지는 데 몇 분 걸려 그 전에는 거부된다
  member_release_at = "at(${replace(timeadd("${var.member_expires_at}Z", "30m"), "Z", "")})"

  member_instance_ids = concat(
    [module.compute.monitoring_instance_id],
    module.compute.load_test_instance_ids,
  )
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "member_cleanup_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "member_cleanup" {
  name               = "${var.project}-member-cleanup"
  assume_role_policy = data.aws_iam_policy_document.member_cleanup_assume.json
}

# 팀원 자기 계정 안의 시험 환경이라 리소스를 좁히지 않는다. 시각이 지나야만 쓰인다
data "aws_iam_policy_document" "member_cleanup" {
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:UpdateAutoScalingGroup",
      "ec2:TerminateInstances",
      "ec2:DeleteNatGateway",
      "ec2:ReleaseAddress",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticache:DeleteReplicationGroup",
      "rds:DeleteDBInstance",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "member_cleanup" {
  name   = "member-cleanup"
  role   = aws_iam_role.member_cleanup.id
  policy = data.aws_iam_policy_document.member_cleanup.json
}

resource "aws_scheduler_schedule" "member_asg" {
  for_each = {
    app   = module.compute.app_asg_name
    batch = module.compute.batch_asg_name
  }

  name                         = "${var.project}-member-cleanup-asg-${each.key}"
  schedule_expression          = local.member_cleanup_at
  schedule_expression_timezone = "UTC"
  action_after_completion      = "DELETE"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:autoscaling:updateAutoScalingGroup"
    role_arn = aws_iam_role.member_cleanup.arn
    input = jsonencode({
      AutoScalingGroupName = each.value
      MinSize              = 0
      MaxSize              = 0
      DesiredCapacity      = 0
    })
  }
}

resource "aws_scheduler_schedule" "member_instances" {
  name                         = "${var.project}-member-cleanup-instances"
  schedule_expression          = local.member_cleanup_at
  schedule_expression_timezone = "UTC"
  action_after_completion      = "DELETE"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:terminateInstances"
    role_arn = aws_iam_role.member_cleanup.arn
    input    = jsonencode({ InstanceIds = local.member_instance_ids })
  }
}

resource "aws_scheduler_schedule" "member_nat" {
  for_each = module.network.nat_gateway_ids

  name                         = "${var.project}-member-cleanup-nat-${each.key}"
  schedule_expression          = local.member_cleanup_at
  schedule_expression_timezone = "UTC"
  action_after_completion      = "DELETE"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:deleteNatGateway"
    role_arn = aws_iam_role.member_cleanup.arn
    input    = jsonencode({ NatGatewayId = each.value })
  }
}

resource "aws_scheduler_schedule" "member_eip" {
  for_each = module.network.nat_eip_allocation_ids

  name                         = "${var.project}-member-cleanup-eip-${each.key}"
  schedule_expression          = local.member_release_at
  schedule_expression_timezone = "UTC"
  action_after_completion      = "DELETE"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:releaseAddress"
    role_arn = aws_iam_role.member_cleanup.arn
    input    = jsonencode({ AllocationId = each.value })
  }
}

resource "aws_scheduler_schedule" "member_alb" {
  name                         = "${var.project}-member-cleanup-alb"
  schedule_expression          = local.member_cleanup_at
  schedule_expression_timezone = "UTC"
  action_after_completion      = "DELETE"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:elasticloadbalancingv2:deleteLoadBalancer"
    role_arn = aws_iam_role.member_cleanup.arn
    input    = jsonencode({ LoadBalancerArn = module.edge.alb_arn })
  }
}

resource "aws_scheduler_schedule" "member_cache" {
  name                         = "${var.project}-member-cleanup-cache"
  schedule_expression          = local.member_cleanup_at
  schedule_expression_timezone = "UTC"
  action_after_completion      = "DELETE"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:elasticache:deleteReplicationGroup"
    role_arn = aws_iam_role.member_cleanup.arn
    input = jsonencode({
      ReplicationGroupId   = module.data.cache_replication_group_id
      RetainPrimaryCluster = false
    })
  }
}

# 시험 데이터는 버려도 된다. 스냅샷을 남기지 않는다
resource "aws_scheduler_schedule" "member_db" {
  name                         = "${var.project}-member-cleanup-db"
  schedule_expression          = local.member_cleanup_at
  schedule_expression_timezone = "UTC"
  action_after_completion      = "DELETE"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:rds:deleteDBInstance"
    role_arn = aws_iam_role.member_cleanup.arn
    input = jsonencode({
      DbInstanceIdentifier   = module.data.db_identifier
      SkipFinalSnapshot      = true
      DeleteAutomatedBackups = true
    })
  }
}

output "member_expires_at" {
  description = "자동 정리 시각 (UTC)"
  value       = var.member_expires_at
}

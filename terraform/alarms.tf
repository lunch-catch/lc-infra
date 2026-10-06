/*
 * CloudWatch 에 두는 판단 기준은 하나다. "모니터링 인스턴스가 죽어도 알아야 하는가".
 * 나머지는 Prometheus 가 본다. 무료 한도가 알람 지표 10개라 그 안에 둔다 (INF-31).
 * 앱 스케일링 정책이 알람 2개를 자동으로 만들므로 그것까지 센다.
 *
 *   항상            monitoring-status, healthy-host-count, batch-capacity, 정책 2개   5개
 *   도메인이 있으면  cert-expiry, endpoint-health(us-east-1)                          +2개
 *
 * 도메인을 붙이면 7개로 INF-12-14 의 상한 6 을 하나 넘는다 (2026-10-06 batch-capacity 추가).
 * 무료 한도는 리전마다 10개라 비용은 없다. 상한을 7 로 올릴지는 pending-decisions 1.6 에 있다.
 *
 * 이상 탐지, 복합 알람, 고해상도 알람, 커스텀 지표, CloudWatch 대시보드는 쓰지 않는다.
 * 각각 별도 과금이라 예산을 조용히 갉아먹는다.
 */

resource "aws_sns_topic" "critical" {
  name         = "${var.project}-critical"
  display_name = "critical"
}

/*
 * AWS Chatbot 이 이 주제를 구독해 Slack 으로 옮긴다.
 * Chatbot 설정 자체는 콘솔 작업이라 여기서 하지 않는다. 주제만 만들어 둔다.
 * 이메일 구독은 Chatbot 이 죽었을 때의 대체 경로다.
 */
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.critical.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# 모니터링 인스턴스가 죽으면 Prometheus 알람이 전부 침묵한다. 이것만은 밖에서 봐야 한다.
resource "aws_cloudwatch_metric_alarm" "monitoring_status" {
  alarm_name          = "${var.project}-monitoring-status"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_description   = "monitoring instance status check failed. restart it"

  dimensions = {
    InstanceId = aws_instance.monitoring.id
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
}

/*
 * 배치 ASG 가 두 대를 채우지 못하고 있다.
 *
 * Prometheus 의 BatchDegraded 와 BatchAllDown 이 먼저 울리지만, 그것은 모니터링 인스턴스가
 * 살아 있을 때뿐이다. 배치와 모니터링이 같은 사건(AZ 장애 등)으로 함께 죽으면 아무도 알리지 않는다.
 *
 * 인스턴스별 상태 검사가 아니라 그룹 지표를 본다. ASG 가 교체할 때마다 인스턴스 ID 가 바뀌어
 * 인스턴스에 건 알람은 첫 교체 뒤 아무것도 보지 않게 된다. 교체도 ASG 가 하므로 알람은 알리기만 한다.
 *
 * 단일 지표로 둔다(INF-12-14). desired 와 견주는 수식을 쓰면 stop.sh 로 내렸을 때 안 울리지만
 * 지표가 둘이 된다. 대신 stop.sh 가 healthy-host-count 와 함께 이 알람의 알림을 끄고 start.sh 가 켠다.
 *
 * 10분을 기다리는 것은 ASG 교체와 instance refresh 가 한 대를 띄우는 데 그만큼 걸리기 때문이다.
 * 그 사이에는 다른 한 대가 작업을 맡고 있다.
 */
resource "aws_cloudwatch_metric_alarm" "batch_capacity" {
  alarm_name          = "${var.project}-batch-capacity"
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 10
  threshold           = 2
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_description   = "batch ASG has fewer than 2 in-service instances. the other batch takes over meanwhile"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.batch.name
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
}

# 정상 대상이 0이면 ALB 가 fail-open 으로 아무 데나 보낸다. 서비스가 사실상 끊긴 상태다.
resource "aws_cloudwatch_metric_alarm" "healthy_host_count" {
  alarm_name          = "${var.project}-healthy-host-count"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  alarm_description   = "no healthy targets. check the app"
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
}

/*
 * 인증서 갱신은 조용히 실패한다.
 * ACM DNS 검증은 자동 갱신되지만 검증 레코드가 사라지면 만료 시점에야 드러난다.
 */
resource "aws_cloudwatch_metric_alarm" "cert_expiry" {
  count = local.has_domain ? 1 : 0

  alarm_name          = "${var.project}-cert-expiry"
  namespace           = "AWS/CertificateManager"
  metric_name         = "DaysToExpiry"
  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 30
  comparison_operator = "LessThanThreshold"
  alarm_description   = "certificate expires in under 30 days. check validation record"

  dimensions = {
    CertificateArn = aws_acm_certificate.main[0].arn
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
}

/*
 * VPC 밖에서 보는 눈이다 (INF-19).
 * Prometheus 는 VPC 안이라 ALB 가 죽어도 앱 지표는 정상으로 보인다.
 * Route 53 지표는 us-east-1 에만 올라오므로 알람도 거기에 만든다.
 */
resource "aws_sns_topic" "critical_us_east_1" {
  count = local.has_domain ? 1 : 0

  provider     = aws.us_east_1
  name         = "${var.project}-critical"
  display_name = "critical"
}

resource "aws_cloudwatch_metric_alarm" "endpoint_health" {
  count = local.has_domain ? 1 : 0

  provider            = aws.us_east_1
  alarm_name          = "${var.project}-endpoint-health"
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  alarm_description   = "service unreachable from outside"

  dimensions = {
    HealthCheckId = aws_route53_health_check.endpoint[0].id
  }

  alarm_actions = [aws_sns_topic.critical_us_east_1[0].arn]
  ok_actions    = [aws_sns_topic.critical_us_east_1[0].arn]
}

/*
 * 지표 알람이 아니라 이벤트 구독이다.
 * 페일오버는 값이 아니라 사건이라 CloudWatch 지표로 표현되지 않는다.
 */
resource "aws_db_event_subscription" "failover" {
  name             = "${var.project}-failover"
  sns_topic        = aws_sns_topic.critical.arn
  source_type      = "db-instance"
  source_ids       = [aws_db_instance.main.identifier]
  event_categories = ["failover"]
}

/*
 * 백업 미생성 알람은 임계값이 정해지지 않아 만들지 않는다.
 * LatestRestorableTime 이 몇 분 이상 밀리면 이상인지를 정하려면 정상 구간의 값을 먼저 봐야 한다.
 * 문서 10.1절이 (미정) 으로 남겨 둔 항목이다. 지어내지 않는다.
 */

/*
 * 예산 초과 알림 (기술 스택 확정 문서 6.5절).
 * 무료다. AWS Budgets 는 계정당 두 개까지 요금이 없다.
 *
 * 알람과 다른 축을 본다.
 * CloudWatch 알람은 "지금 고장났는가" 를, 예산은 "이대로 가면 돈이 얼마나 나가는가" 를 본다.
 */

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 이미 쓴 금액이 절반을 넘었다. 아직 조치할 시간이 있다.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.critical.arn]
    subscriber_email_addresses = var.alert_email != "" ? [var.alert_email] : []
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.critical.arn]
    subscriber_email_addresses = var.alert_email != "" ? [var.alert_email] : []
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.critical.arn]
    subscriber_email_addresses = var.alert_email != "" ? [var.alert_email] : []
  }

  /*
   * 실제 지출이 아니라 예측치를 본다.
   * 실제가 100% 를 넘었을 때는 이미 늦다. 이번 달 끝에 얼마가 될지를 미리 알린다.
   */
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.critical.arn]
    subscriber_email_addresses = var.alert_email != "" ? [var.alert_email] : []
  }
}

/*
 * SNS 주제가 예산 알림을 받으려면 budgets 서비스에 게시 권한을 줘야 한다.
 * 이것이 없으면 예산은 만들어지는데 알림이 조용히 안 온다.
 */
data "aws_iam_policy_document" "sns_budgets" {
  statement {
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.critical.arn]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "critical" {
  arn    = aws_sns_topic.critical.arn
  policy = data.aws_iam_policy_document.sns_budgets.json
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.main.arn
}

output "alb_arn_suffix" {
  description = "CloudWatch 지표 차원과 스케일링 정책이 쓰는 ALB 식별자"
  value       = aws_lb.main.arn_suffix
}

output "alb_dns_name" {
  description = "도메인이 없을 때 접속할 주소"
  value       = aws_lb.main.dns_name
}

output "app_target_group_arn" {
  description = "앱 트래픽 대상 그룹"
  value       = aws_lb_target_group.app.arn
}

output "app_target_group_arn_suffix" {
  description = "CloudWatch 지표 차원과 스케일링 정책이 쓰는 앱 대상 그룹 식별자"
  value       = aws_lb_target_group.app.arn_suffix
}

output "liveness_target_group_arn" {
  description = "외부 감시용 liveness 대상 그룹"
  value       = aws_lb_target_group.liveness.arn
}

output "grafana_target_group_arn" {
  description = "Grafana 대상 그룹. ALB 경로를 안 쓰면 null 이다"
  value       = local.has_grafana ? aws_lb_target_group.grafana[0].arn : null
}

output "grafana_host" {
  description = "Grafana 호스트 이름. 도메인이 없으면 빈 문자열이다"
  value       = local.grafana_host
}

/*
 * 리소스 속성이 아니라 계산한 이름을 내보낸다.
 * 사용자 데이터 템플릿이 plan 시점에 값을 알아야 한다.
 */
output "media_bucket" {
  description = "이미지 버킷 이름"
  value       = local.media_bucket
}

output "cdn_domain" {
  description = "앱의 cdn.base-url 에 넣을 값. 도메인이 있으면 고정 주소다"
  value       = local.has_domain ? local.cdn_host : aws_cloudfront_distribution.media.domain_name
}

output "certificate_arn" {
  description = "API 인증서 ARN. 도메인이 없으면 null 이다"
  value       = local.has_domain ? aws_acm_certificate.main[0].arn : null
}

output "endpoint_health_check_id" {
  description = "외부 감시 Route 53 헬스체크 ID. 도메인이 없으면 null 이다"
  value       = local.has_domain ? aws_route53_health_check.endpoint[0].id : null
}

variable "project" {
  description = "모든 리소스 이름의 접두사"
  type        = string
}

variable "monitoring_instance_id" {
  description = "상태 검사 알람이 볼 모니터링 인스턴스"
  type        = string
}

variable "batch_asg_name" {
  description = "batch-capacity 알람이 볼 배치 ASG"
  type        = string
}

variable "alb_arn_suffix" {
  description = "healthy-host-count 알람이 볼 ALB 식별자"
  type        = string
}

variable "app_target_group_arn_suffix" {
  description = "healthy-host-count 알람이 볼 앱 대상 그룹 식별자"
  type        = string
}

variable "db_identifier" {
  description = "페일오버 이벤트를 구독할 RDS 인스턴스"
  type        = string
}

# 도메인이 있을 때만 인증서 만료와 외부 감시 알람을 만든다.
variable "domain_enabled" {
  description = "서비스 도메인이 있는지 여부"
  type        = bool
}

variable "certificate_arn" {
  description = "만료를 볼 API 인증서. domain_enabled 가 false 면 null 이다"
  type        = string
  default     = null
}

variable "endpoint_health_check_id" {
  description = "외부 감시 Route 53 헬스체크. domain_enabled 가 false 면 null 이다"
  type        = string
  default     = null
}

/*
 * Chatbot 이 죽었을 때의 대체 경로다.
 * 비우면 이메일 구독을 만들지 않는다.
 */
variable "alert_email" {
  description = "critical 알림을 받을 이메일"
  type        = string
  nullable    = false
  default     = ""
}

/*
 * 월 예산. 기술 스택 확정 문서 5.2절의 추정 총액이 근거다.
 * 프리 티어 크레딧으로 도는 동안에도 소진 속도를 봐야 하므로 값을 둔다.
 */
variable "monthly_budget_usd" {
  description = "월 예산 상한. 50, 80, 100% 와 예측 100% 에서 알린다"
  type        = string
  nullable    = false
  default     = "140"
}

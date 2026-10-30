/*
 * 운영 환경에서 tfvars 나 스크립트가 고르는 값만 둔다.
 * 조정값의 기본값과 근거는 각 모듈의 variables.tf 에 있다. 여기서 null 로 두면 모듈 기본값을 쓴다.
 */

/*
 * 계정을 여럿 쓰는 환경에서 어느 자격증명을 쓸지 고른다.
 * 비우면 기본 자격증명이나 환경변수를 쓴다.
 */
variable "aws_profile" {
  description = "AWS CLI 프로파일 이름"
  type        = string
  default     = ""
}

/*
 * 잘못된 계정에 apply 하는 사고를 막는 마지막 방어다.
 * 프로파일을 잘못 잡거나 환경변수가 남아 있으면 plan 단계에서 멈춘다.
 * 비워 두면 검사하지 않는다.
 */
variable "allowed_account_ids" {
  description = "이 구성을 적용해도 되는 AWS 계정 ID"
  type        = list(string)
  default     = []
}

variable "project" {
  description = "모든 리소스 이름과 SSM 경로의 접두사"
  type        = string
  default     = "lunchcatch"
}

variable "region" {
  description = "AWS 리전. 범위가 단일 리전이다 (INF-01)"
  type        = string
  default     = "ap-northeast-2"
}

/*
 * 비어 있으면 Route 53 과 ACM 과 HTTPS 리스너를 만들지 않는다.
 * 도메인이 생기면 이 값만 채워 apply 한다.
 */
variable "domain_name" {
  description = "서비스 도메인. 예: api.example.com"
  type        = string
  default     = ""
}

/*
 * 비어 있으면 Grafana 를 ALB 에 붙이지 않는다.
 * 값이 있어도 domain_name 이 비어 있으면 붙이지 않는다. OIDC 인증은 HTTPS 리스너에서만 되기 때문이다.
 *
 * 클라이언트 ID 는 시크릿이 아니다. OAuth 흐름에서 브라우저에 그대로 드러난다.
 * 시크릿은 SSM 의 grafana-oidc-client-secret 에서 읽는다.
 */
variable "grafana_oidc_client_id" {
  description = "Google OAuth 클라이언트 ID. 비우면 Grafana 를 노출하지 않는다"
  type        = string
  default     = ""
}

/*
 * 도메인을 사기 전까지 쓰는 임시 경로다. 비우면 아무것도 만들지 않는다.
 *
 * ALB 를 거치지 않는다. 모니터링 인스턴스의 Caddy 가 직접 TLS 를 종료하고
 * Let's Encrypt 에서 인증서를 받는다. ACM 은 도메인 소유 검증이 필요해 쓸 수 없다.
 *
 * domain_name 이 생기면 이 값을 비운다. 두 경로를 동시에 켜지 않는다.
 */
variable "duckdns_hostname" {
  description = "DuckDNS 호스트명. 예: lunchcatch.duckdns.org"
  type        = string
  default     = ""
}

variable "load_test_enabled" {
  description = "부하 생성 인스턴스를 띄울지 여부"
  type        = bool
  default     = false
}

/*
 * Chatbot 이 죽었을 때의 대체 경로다.
 * 비우면 이메일 구독을 만들지 않는다.
 */
variable "alert_email" {
  description = "critical 알림을 받을 이메일"
  type        = string
  default     = ""
}

/*
 * AWS 쪽 삭제 보호를 한 번에 켜고 끈다.
 * RDS 삭제 보호와 최종 스냅샷, ALB 삭제 보호, 모니터링 종료 보호와 볼륨 보존, S3 와 ECR 의 비우기 거부가 이것을 따른다.
 * 끄는 것은 destroy.sh 가 파괴 직전에 -var 로 넘길 때뿐이다. tfvars 에 적지 않는다.
 */
variable "deletion_protection" {
  description = "데이터를 가진 리소스의 AWS 쪽 삭제 보호"
  type        = bool
  default     = true
}

# 기본값과 근거는 modules/compute/variables.tf 에 있다.
variable "instance_types" {
  description = "역할별 인스턴스 타입"
  type        = map(string)
  default     = null
}

# 기본값과 근거는 modules/compute/variables.tf 에 있다.
variable "app_target_requests_per_instance" {
  description = "앱 ASG 확장 기준. 대상당 분당 요청 수"
  type        = number
  default     = null
}

# 기본값과 근거는 modules/compute/variables.tf 에 있다.
variable "app_image_repository" {
  description = "앱 이미지 저장소 주소. 비우면 이 계정의 ECR 을 쓴다"
  type        = string
  default     = null
}

# 기본값과 근거는 modules/edge/variables.tf 에 있다.
variable "media_bucket_name" {
  description = "이미지 버킷 이름. null 이면 {project}-media 를 쓴다"
  type        = string
  default     = null
}

# 기본값과 근거는 modules/network/variables.tf 에 있다.
variable "grafana_https_allowed_cidrs" {
  description = "Caddy 443 을 열어 줄 CIDR 목록"
  type        = list(string)
  default     = null
}

# 기본값과 근거는 modules/data/variables.tf 에 있다.
variable "db_instance_class" {
  description = "RDS 인스턴스 클래스"
  type        = string
  default     = null
}

# 기본값과 근거는 modules/data/variables.tf 에 있다.
variable "db_multi_az" {
  description = "RDS Multi-AZ 여부"
  type        = bool
  default     = null
}

# 기본값과 근거는 modules/data/variables.tf 에 있다.
variable "db_backup_retention_days" {
  description = "RDS 자동 백업 보존 기간"
  type        = number
  default     = null
}

# 기본값과 근거는 modules/data/variables.tf 에 있다.
variable "db_backup_window" {
  description = "RDS 자동 백업 창 (UTC)"
  type        = string
  default     = null
}

# 기본값과 근거는 modules/data/variables.tf 에 있다.
variable "db_maintenance_window" {
  description = "RDS 유지보수 창 (UTC)"
  type        = string
  default     = null
}

# 기본값과 근거는 modules/data/variables.tf 에 있다.
variable "cache_node_type" {
  description = "ElastiCache 노드 타입"
  type        = string
  default     = null
}

# 기본값과 근거는 modules/observability/variables.tf 에 있다.
variable "monthly_budget_usd" {
  description = "월 예산 상한"
  type        = string
  default     = null
}

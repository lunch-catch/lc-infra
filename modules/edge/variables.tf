variable "project" {
  description = "모든 리소스 이름과 SSM 경로의 접두사"
  type        = string
}

variable "vpc_id" {
  description = "대상 그룹을 둘 VPC"
  type        = string
}

variable "public_subnet_ids" {
  description = "ALB 를 둘 퍼블릭 서브넷 ID"
  type        = map(string)
}

variable "alb_security_group_id" {
  description = "ALB 에 붙일 보안 그룹"
  type        = string
}

/*
 * AWS 쪽 삭제 보호다. ALB 의 삭제 보호와 미디어 버킷의 force_destroy 가 이것을 따른다.
 * 운영은 켜 두고 destroy.sh 가 파괴 직전에만 끈다. 부하 시험 환경은 꺼 둔다.
 */
variable "deletion_protection" {
  description = "ALB 삭제 보호, 미디어 버킷 비우기 거부 여부"
  type        = bool
}

/*
 * 비어 있으면 Route 53 과 ACM 과 HTTPS 리스너를 만들지 않는다.
 * 도메인이 생기면 이 값만 채워 apply 한다.
 */
variable "domain_name" {
  description = "서비스 도메인. 예: api.example.com"
  type        = string
  nullable    = false
}

# Grafana 를 붙일 서브도메인. 인증서 SAN 과 호스트 헤더 조건이 이 값을 쓴다.
variable "grafana_subdomain" {
  description = "Grafana 서브도메인 라벨. 예: grafana"
  type        = string
  nullable    = false
  default     = "grafana"
}

/*
 * Grafana 를 ALB 에 붙이는 조건이다.
 * OIDC 인증 액션은 HTTPS 리스너에만 붙일 수 있어 도메인이 전제다.
 * 클라이언트 ID 가 없으면 인증 없이 노출하게 되므로 그때도 붙이지 않는다.
 * 보안 그룹(network)과 SSM 값(compute)도 같은 판단을 따라야 해서 부르는 쪽이 한 번 계산해 넘긴다.
 */
variable "grafana_alb_enabled" {
  description = "Grafana 를 ALB 뒤에 붙이는지 여부"
  type        = bool
}

/*
 * 클라이언트 ID 는 시크릿이 아니다. OAuth 흐름에서 브라우저에 그대로 드러난다.
 * 시크릿은 SSM 의 grafana-oidc-client-secret 에서 읽는다.
 */
variable "grafana_oidc_client_id" {
  description = "Google OAuth 클라이언트 ID"
  type        = string
  nullable    = false
  default     = ""
}

variable "media_bucket_name" {
  description = "이미지 버킷 이름. null 이거나 비어 있으면 {project}-media 를 쓴다"
  type        = string
  default     = null
}

/*
 * presigned PUT 이 브라우저에서 직접 간다.
 * 프론트 도메인이 정해지면 좁힌다.
 */
variable "media_cors_origins" {
  description = "이미지 업로드를 허용할 오리진"
  type        = list(string)
  nullable    = false
  default     = ["*"]
}

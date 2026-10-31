variable "project" {
  description = "모든 리소스 이름의 접두사"
  type        = string
}

variable "region" {
  description = "AWS 리전. S3 게이트웨이 엔드포인트 이름에 쓴다"
  type        = string
}

/*
 * AWS 는 계정마다 AZ 이름을 다른 물리 영역에 매핑한다.
 * 그래서 이 값은 이 계정 기준이며 변수로 둔다.
 */
variable "azs" {
  description = "논리 AZ 이름을 실제 AZ 에 매핑한다"
  type        = map(string)
  nullable    = false

  default = {
    a = "ap-northeast-2a"
    c = "ap-northeast-2c"
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  nullable    = false
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "퍼블릭 서브넷. ALB, NAT, 부하 생성기"
  type        = map(string)
  nullable    = false

  default = {
    a = "10.0.1.0/24"
    c = "10.0.2.0/24"
  }
}

variable "private_subnet_cidrs" {
  description = "프라이빗 서브넷. 앱, 배치, 모니터링, RDS, ElastiCache"
  type        = map(string)
  nullable    = false

  default = {
    a = "10.0.11.0/24"
    c = "10.0.12.0/24"
  }
}

/*
 * edge 모듈이 Grafana 를 ALB 뒤에 붙일 때 true 다.
 * 그때만 ALB -> 3000 을 연다.
 */
variable "grafana_alb_enabled" {
  description = "Grafana 를 ALB 뒤에 붙이는지 여부"
  type        = bool
}

/*
 * DuckDNS 경로를 쓸 때 true 다.
 * 그때만 모니터링의 80 과 443 을 연다.
 */
variable "duckdns_enabled" {
  description = "모니터링 인스턴스의 Caddy 가 직접 TLS 를 받는지 여부"
  type        = bool
}

/*
 * Caddy 의 443 을 열어 줄 대역이다.
 *
 * 기본값이 전체 공개인 것은 Caddy 의 basic_auth 가 인증 전 요청을 막기 때문이다.
 * 팀이 고정 IP 를 쓴다면 좁히는 편이 낫다. VPN 출구 IP 는 공유되고 바뀌므로 좁히는 의미가 적다.
 */
variable "grafana_https_allowed_cidrs" {
  description = "Caddy 443 을 열어 줄 CIDR 목록"
  type        = list(string)
  nullable    = false
  default     = ["0.0.0.0/0"]
}

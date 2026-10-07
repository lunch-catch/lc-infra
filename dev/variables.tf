variable "project" {
  description = "리소스 이름과 SSM 경로의 접두사. 운영과 같다"
  type        = string
  default     = "lunchcatch"
}

variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI 프로파일 이름. 비우면 기본 자격증명을 쓴다"
  type        = string
  default     = ""
}

variable "allowed_account_ids" {
  description = "이 구성을 적용해도 되는 AWS 계정 ID"
  type        = list(string)
  default     = []
}

# 호스팅 영역 이름이다. bootstrap/ 의 zone_name 과 같아야 한다.
variable "zone_name" {
  description = "서비스 도메인"
  type        = string
  default     = "lunchcatch.com"
}

# 운영 주소에 dev. 를 끼운다 (개발 서버 문서 3.1절).
variable "api_host" {
  description = "개발 백엔드 주소"
  type        = string
  default     = "api.dev.lunchcatch.com"
}

/*
 * 개발 프론트 주소다. 개발 백엔드의 CORS 허용 출처가 된다.
 * 프론트가 Vercel 에서 develop 브랜치를 붙일 주소와 같아야 한다.
 */
variable "frontend_origins" {
  description = "개발 백엔드가 받는 출처"
  type        = list(string)
  default = [
    "https://dev.lunchcatch.com",
    "https://owner.dev.lunchcatch.com",
    "https://admin.dev.lunchcatch.com",
  ]
}

/*
 * 메모리 2 GB 에 앱, MySQL, Valkey, Caddy 를 함께 올린다. 컨테이너마다 상한을 건다 (문서 4장).
 * 부족하면 t3.medium 으로 올린다. 시간당 두 배다.
 */
variable "instance_type" {
  description = "개발 서버 인스턴스 타입"
  type        = string
  default     = "t3.small"
}

# 운영 VPC(10.0.0.0/16)와 겹치지 않게 둔다. 나중에 둘을 이을 일이 생겨도 충돌하지 않는다.
variable "vpc_cidr" {
  description = "개발 VPC CIDR"
  type        = string
  default     = "10.10.0.0/16"
}

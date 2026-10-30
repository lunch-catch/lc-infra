/*
 * 값은 member-env.sh 가 변수 파일로 넘긴다.
 * 손으로 고치지 않는다.
 */

variable "project" {
  description = "모든 리소스 이름과 SSM 경로의 접두사. 우리 계정에서는 운영과 겹치지 않게 lunchcatch-lt 를 쓴다"
  type        = string
}

variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "allowed_account_ids" {
  description = "이 구성을 적용해도 되는 AWS 계정 ID. member-env.sh 를 부른 계정 하나다"
  type        = list(string)
}

variable "alert_email" {
  description = "예산 알림과 경보를 받을 이메일. 비우면 구독을 만들지 않는다"
  type        = string
  default     = ""
}

variable "media_bucket_name" {
  description = "이미지 버킷 이름. 버킷 이름은 전 세계에서 유일해야 해서 계정 ID 를 붙인다"
  type        = string
}

variable "app_image_repository" {
  description = "앱 이미지 저장소 주소. 우리 계정의 개발 ECR 을 가리킨다"
  type        = string
}

variable "load_test_enabled" {
  description = "부하 생성 인스턴스를 띄울지 여부"
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "월 예산 상한"
  type        = string
  default     = "50"
}

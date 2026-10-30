variable "project" {
  description = "모든 리소스 이름과 SSM 경로의 접두사"
  type        = string
}

variable "azs" {
  description = "논리 AZ 이름을 실제 AZ 에 매핑한다. a 와 c 가 있어야 한다"
  type        = map(string)
}

variable "private_subnet_ids" {
  description = "RDS 와 캐시 서브넷 그룹에 넣을 프라이빗 서브넷 ID"
  type        = map(string)
}

variable "db_security_group_id" {
  description = "RDS 에 붙일 보안 그룹"
  type        = string
}

variable "cache_security_group_id" {
  description = "캐시에 붙일 보안 그룹"
  type        = string
}

/*
 * AWS 쪽 삭제 보호다. RDS 의 deletion_protection 과 최종 스냅샷이 이것을 따른다.
 * 운영은 켜 두고 destroy.sh 가 파괴 직전에만 끈다. 부하 시험 환경은 꺼 둔다.
 */
variable "deletion_protection" {
  description = "RDS 삭제 보호와 최종 스냅샷 여부"
  type        = bool
}

variable "db_name" {
  description = "데이터베이스 이름. backend 의 compose.yaml 과 같아야 한다"
  type        = string
  nullable    = false
  default     = "lunchcatch"
}

variable "db_username" {
  description = "DB 마스터 사용자"
  type        = string
  nullable    = false
  default     = "lunchcatch"
}

variable "db_instance_class" {
  description = "RDS 인스턴스 클래스"
  type        = string
  nullable    = false
  default     = "db.t4g.micro"
}

/*
 * 확정값이고 2026-08-28 부터 켜져 있다 (기술 스택 확정 문서 2.6절).
 *
 * 기본값을 true 로 둔다. tfvars 는 gitignore 대상이라 거기에만 있으면
 * 다른 사람이 apply 할 때 조용히 Single-AZ 로 내려간다. RTO 2분과 RPO 0 목표가
 * 그 순간 성립하지 않게 되는데 plan 에서 눈에 잘 띄지 않는다.
 *
 * 끄려면 tfvars 에 명시적으로 false 를 적는다. 그 편이 의도가 드러난다.
 */
variable "db_multi_az" {
  description = "RDS Multi-AZ 여부. false 인 동안은 RTO 2분과 RPO 0 목표가 성립하지 않는다"
  type        = bool
  nullable    = false
  default     = true
}

/*
 * 확정값은 7일이다 (백업과복원 설계 3.1절). PITR 로 되돌릴 수 있는 범위를 정한다.
 *
 * 프리 티어 FREE 플랜은 이 값에 상한이 있어 7을 거부한다.
 *   FreeTierRestrictionError: The specified backup retention period exceeds
 *   the maximum available to free tier customers.
 *
 * 유료 플랜으로 올린 뒤 7로 되돌린다. 그 전까지는 복구 가능 범위가 그만큼 좁다.
 */
variable "db_backup_retention_days" {
  description = "RDS 자동 백업 보존 기간. 확정값은 7이고 프리 티어에서만 낮춘다"
  type        = number
  nullable    = false
  default     = 7
}

/*
 * 문서가 "트래픽이 가장 적은 시간대" 로만 정해 두었다.
 * 실제 패턴을 보고 확정한다.
 */
variable "db_backup_window" {
  description = "RDS 자동 백업 창 (UTC). 기본값은 KST 새벽 3시다"
  type        = string
  nullable    = false
  default     = "18:00-19:00"
}

variable "db_maintenance_window" {
  description = "RDS 유지보수 창 (UTC). 백업 창과 겹치지 않게 둔다"
  type        = string
  nullable    = false
  default     = "sun:19:30-sun:20:30"
}

variable "cache_node_type" {
  description = "ElastiCache 노드 타입"
  type        = string
  nullable    = false
  default     = "cache.t4g.micro"
}

output "db_address" {
  description = "RDS 엔드포인트 주소. SSM db-endpoint 의 초기값이다"
  value       = aws_db_instance.main.address
}

output "db_identifier" {
  description = "RDS 인스턴스 식별자. 페일오버 이벤트 구독과 자동 정리가 쓴다"
  value       = aws_db_instance.main.identifier
}

/*
 * 리소스 속성이 아니라 변수를 내보낸다.
 * 사용자 데이터 템플릿이 plan 시점에 값을 알아야 한다.
 */
output "db_name" {
  description = "데이터베이스 이름"
  value       = var.db_name
}

output "db_username" {
  description = "DB 마스터 사용자"
  value       = var.db_username
}

output "cache_endpoint" {
  description = "캐시 프라이머리 주소. SSM cache-endpoint 의 초기값이다"
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "cache_replication_group_id" {
  description = "캐시 복제 그룹 ID. 자동 정리가 쓴다"
  value       = aws_elasticache_replication_group.main.id
}

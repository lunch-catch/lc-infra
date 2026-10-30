/*
 * 배포 스크립트와 preflight 스크립트가 이 값들을 읽는다.
 * 이름을 바꾸면 scripts/ 도 함께 고친다.
 */

output "vpc_id" {
  description = "VPC ID"
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID"
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID"
  value       = module.network.private_subnet_ids
}

output "security_group_ids" {
  description = "역할별 보안 그룹 ID"
  value       = module.network.security_group_ids
}

output "db_endpoint" {
  description = "SSM db-endpoint 파라미터에 넣을 값"
  value       = module.data.db_address
}

output "cache_endpoint" {
  description = "앱이 접속할 캐시 주소"
  value       = module.data.cache_endpoint
}

output "alb_dns_name" {
  description = "도메인이 없을 때 접속할 주소"
  value       = module.edge.alb_dns_name
}

output "asg_name" {
  description = "배포 스크립트가 desired 를 조절할 대상"
  value       = module.compute.app_asg_name
}

output "target_group_arn" {
  description = "배포 스크립트가 healthy 수를 확인할 대상"
  value       = module.edge.app_target_group_arn
}

output "media_bucket" {
  description = "이미지 버킷 이름"
  value       = module.edge.media_bucket
}

output "cdn_domain" {
  description = "앱의 cdn.base-url 에 넣을 값. 도메인이 있으면 고정 주소다"
  value       = module.edge.cdn_domain
}

output "grafana_url" {
  description = "Grafana 접속 주소. 비어 있으면 SSM 포트 포워딩으로만 볼 수 있다"
  value       = module.compute.grafana_url
}

output "monitoring_public_ip" {
  description = "모니터링 인스턴스 고정 IP. DuckDNS 를 쓸 때만 값이 생긴다"
  value       = module.compute.monitoring_public_ip
}

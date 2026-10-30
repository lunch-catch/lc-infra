output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "azs" {
  description = "논리 AZ 이름과 실제 AZ 의 매핑. 캐시가 프라이머리와 복제본 자리를 고를 때 쓴다"
  value       = var.azs
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID. 키는 논리 AZ 이름이다"
  value       = { for k, s in aws_subnet.public : k => s.id }
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID. 키는 논리 AZ 이름이다"
  value       = { for k, s in aws_subnet.private : k => s.id }
}

output "security_group_ids" {
  description = "역할별 보안 그룹 ID"

  value = {
    alb      = aws_security_group.alb.id
    app      = aws_security_group.app.id
    db       = aws_security_group.db.id
    cache    = aws_security_group.cache.id
    mon      = aws_security_group.mon.id
    batch    = aws_security_group.batch.id
    loadtest = aws_security_group.loadtest.id
  }
}

# 부하 시험 환경의 자동 정리가 시각이 되면 이 둘을 지운다 (envs/lt/cleanup.tf).
output "nat_gateway_ids" {
  description = "AZ 별 NAT Gateway ID"
  value       = { for k, n in aws_nat_gateway.main : k => n.id }
}

output "nat_eip_allocation_ids" {
  description = "AZ 별 NAT 고정 IP 의 할당 ID"
  value       = { for k, e in aws_eip.nat : k => e.id }
}

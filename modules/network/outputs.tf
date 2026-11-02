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

/*
 * 값은 private_subnet_ids 와 같고, NAT 와 라우팅이 붙은 뒤에야 정해진다 (#76).
 *
 * 서브넷이 생겨도 NAT 경로가 붙기 전에는 밖으로 나가지 못한다. 그 사이에 뜬 서버는 user-data 의
 * apt-get 이 Network is unreachable 로 멈춘다. 2026-11-02 에 RDS 를 기다리지 않게 바꾼(#78) 모니터링이 그렇게 죽었다.
 * 서버를 띄우는 compute 는 이것을 받아 경로가 생긴 뒤에 뜬다. RDS 와 캐시는 밖으로 나갈 일이 없어 그대로 둔다.
 */
output "private_subnet_ids_routed" {
  description = "NAT 경로가 붙은 프라이빗 서브넷 ID. 값은 private_subnet_ids 와 같다"
  value       = { for k, a in aws_route_table_association.private : k => a.subnet_id }
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

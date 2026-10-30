output "app_asg_name" {
  description = "배포 스크립트가 desired 를 조절할 대상"
  value       = aws_autoscaling_group.app.name
}

output "batch_asg_name" {
  description = "배치 ASG 이름. batch-capacity 알람이 본다"
  value       = aws_autoscaling_group.batch.name
}

output "monitoring_instance_id" {
  description = "모니터링 인스턴스 ID. 상태 검사 알람이 본다"
  value       = aws_instance.monitoring.id
}

output "load_test_instance_ids" {
  description = "부하 생성기 인스턴스 ID. 꺼 두면 빈 목록이다"
  value       = [for i in aws_instance.load_test : i.id]
}

output "grafana_url" {
  description = "Grafana 접속 주소. 비어 있으면 SSM 포트 포워딩으로만 볼 수 있다"
  value       = local.grafana_root_url == "unset" ? "" : local.grafana_root_url
}

/*
 * DuckDNS 화면의 current ip 에 넣을 값이다.
 * 이 주소로 인증서가 발급된다.
 */
output "monitoring_public_ip" {
  description = "모니터링 인스턴스 고정 IP. DuckDNS 를 쓸 때만 값이 생긴다"
  value       = local.has_duckdns ? aws_eip.monitoring[0].public_ip : ""
}

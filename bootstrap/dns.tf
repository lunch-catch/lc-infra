/*
 * 서비스 도메인의 호스팅 영역이다. lunchcatch.com 을 Route 53 에서 등록했다 (2026-10-07).
 *
 * 파괴를 견디는 계층에 두는 이유는 네임서버다. 영역을 지웠다 다시 만들면 네임서버 넷이 새로 배정되는데,
 * 도메인 등록 정보의 네임서버는 따라 바뀌지 않는다. terraform/ 에 두면 destroy.sh 를 돌릴 때마다
 * 도메인이 먹통이 되고 등록 정보를 손으로 고쳐야 한다. 영역 유지 비용은 월 0.5 USD 다.
 *
 * 등록할 때 Route 53 이 자동으로 만든 영역을 import 했다. 새로 만들지 않는다.
 *   terraform import 'aws_route53_zone.main[0]' Z03486202JHZN5I319GON
 *
 * 레코드는 여기 두지 않는다. ALB 별칭과 인증서 검증 레코드는 terraform/ 이, 프론트 서브도메인은
 * 그것을 만드는 쪽이 갖는다. 이 계층은 영역의 존재와 네임서버만 지킨다.
 */

variable "zone_name" {
  description = "Route 53 에서 등록한 도메인. 비우면 영역을 관리하지 않는다"
  type        = string
  default     = ""
}

resource "aws_route53_zone" "main" {
  count = var.zone_name != "" ? 1 : 0

  name    = var.zone_name
  comment = "${var.project} service domain. registered in Route 53"

  # 지우면 네임서버가 바뀌어 도메인이 끊긴다. 위 머리 주석을 보라.
  lifecycle {
    prevent_destroy = true
  }
}

output "zone_id" {
  description = "terraform/ 이 이름으로 찾아 쓴다. 확인용"
  value       = var.zone_name != "" ? aws_route53_zone.main[0].zone_id : ""
}

output "name_servers" {
  description = "도메인 등록 정보의 네임서버와 같아야 한다"
  value       = var.zone_name != "" ? aws_route53_zone.main[0].name_servers : []
}

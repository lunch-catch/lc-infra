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
 * 백엔드 레코드(ALB 별칭, 인증서 검증)는 terraform/ 이 갖는다. 백엔드와 함께 생기고 지워진다.
 * 프론트(Vercel) 레코드는 여기 둔다. 백엔드를 내려도 프론트 주소는 살아 있어야 한다.
 * Vercel 프로젝트 자체는 프론트가 대시보드에서 관리한다 (INF-44).
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

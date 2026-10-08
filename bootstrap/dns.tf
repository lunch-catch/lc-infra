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
 * 백엔드 레코드(ALB 별칭, 인증서 검증)는 terraform/ 이, 개발 백엔드(api.dev)는 dev/ 가 갖는다.
 * 프론트(Vercel) 레코드는 이 파일 아래에 둔다. 백엔드를 내려도 프론트 주소는 살아 있어야 한다.
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

/*
 * 프론트(Vercel) 레코드다 (INF-44, 프론트엔드 배포 문서 4.3절).
 * 값은 프론트가 Vercel 의 도메인 화면에서 받아 준 것이다 (2026-10-07).
 * owner 둘의 소유 확인 값은 2026-10-08 에 바뀌었다. 도메인이 다른 프로젝트에 잘못 붙어 있어 옮기면서 다시 받았다. Vercel 이 프로젝트마다 다른
 * 값을 줄 수 있어 손으로 짓지 않는다. 프로젝트를 다시 만들면 값이 바뀌므로 다시 받아 고친다.
 *
 * 백엔드를 destroy 해도 프론트 주소는 살아 있어야 해서 영역과 같은 이 계층에 둔다.
 */
locals {
  has_zone = var.zone_name != ""

  # 사용자 앱이다. 영역의 꼭대기에는 CNAME 을 둘 수 없어 A 레코드로 Vercel 의 IP 를 가리킨다
  vercel_apex_ip = "216.198.79.1"

  # 이름 -> Vercel 이 준 대상. 같은 프로젝트의 운영과 개발은 같은 대상을 가리키고, Vercel 이 이름으로 가른다
  vercel_cnames = {
    "www"       = "48f470cb9dff90d2.vercel-dns-017.com." # user
    "dev"       = "48f470cb9dff90d2.vercel-dns-017.com." # user, develop 브랜치
    "owner"     = "3e78b52f5cceab6b.vercel-dns-017.com." # owner
    "owner.dev" = "3e78b52f5cceab6b.vercel-dns-017.com." # owner, develop 브랜치
    "admin"     = "be3d5fe38cb9fc3f.vercel-dns-017.com." # admin
    "admin.dev" = "be3d5fe38cb9fc3f.vercel-dns-017.com." # admin, develop 브랜치
  }

  /*
   * Vercel 의 소유 확인이다. 도메인이 달라도 이름은 늘 _vercel.<영역> 하나이고 값만 여럿이다.
   * 한 이름에 레코드를 따로 만들면 서로 덮어쓰므로 값을 모아 레코드 하나로 둔다.
   * admin 과 admin.dev 는 Vercel 이 확인을 요구하지 않았다.
   */
  vercel_verify = [
    "vc-domain-verify=lunchcatch.com,1982d63988987db6085a",
    "vc-domain-verify=www.lunchcatch.com,b2e8d015c2995cb190f4",
    "vc-domain-verify=dev.lunchcatch.com,b4eb657e262b3f14e918",
    "vc-domain-verify=owner.lunchcatch.com,e50d8c842d13e790c998",
    "vc-domain-verify=owner.dev.lunchcatch.com,f4ea35c0d4cf62cb0a8f",
  ]
}

resource "aws_route53_record" "vercel_apex" {
  count = local.has_zone ? 1 : 0

  zone_id = aws_route53_zone.main[0].zone_id
  name    = var.zone_name
  type    = "A"
  ttl     = 300
  records = [local.vercel_apex_ip]
}

resource "aws_route53_record" "vercel" {
  for_each = local.has_zone ? local.vercel_cnames : {}

  zone_id = aws_route53_zone.main[0].zone_id
  name    = "${each.key}.${var.zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [each.value]
}

resource "aws_route53_record" "vercel_verify" {
  count = local.has_zone ? 1 : 0

  zone_id = aws_route53_zone.main[0].zone_id
  name    = "_vercel.${var.zone_name}"
  type    = "TXT"
  ttl     = 300
  records = local.vercel_verify
}

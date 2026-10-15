/*
 * 개발 서버의 이미지 저장소다 (이미지저장소 설계 6.2절, 런치캐치_개발서버.md).
 * 구조는 운영(terraform/storage.tf)과 같다. 비공개 버킷에 presigned PUT 으로 올리고 CloudFront + OAC 로 읽는다.
 *
 * 개발 서버(dev/)는 필요할 때만 올리므로, 이미지가 서버를 내려도 남도록 파괴를 견디는 이 계층에 둔다.
 * 주소는 cdn.dev.<도메인> 로 고정한다. CloudFront 기본 주소는 배포를 다시 만들 때마다 바뀐다.
 */

locals {
  dev_media_bucket = "${var.project}-dev-media"
  dev_cdn_host     = var.zone_name != "" ? "cdn.dev.${var.zone_name}" : ""
}

# 브라우저가 presigned PUT 으로 직접 올린다. dev/ 의 frontend_origins 와 같은 셋이다.
variable "dev_media_cors_origins" {
  description = "개발 이미지 업로드를 허용할 오리진"
  type        = list(string)
  default = [
    "https://dev.lunchcatch.com",
    "https://owner.dev.lunchcatch.com",
    "https://admin.dev.lunchcatch.com",
  ]
}

resource "aws_s3_bucket" "dev_media" {
  bucket = local.dev_media_bucket

  # 시험 이미지뿐이다. 버킷을 지울 때 비어 있지 않다고 막히지 않게 한다.
  force_destroy = true

  tags = {
    Name = local.dev_media_bucket
  }
}

resource "aws_s3_bucket_public_access_block" "dev_media" {
  bucket                  = aws_s3_bucket.dev_media.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dev_media" {
  bucket = aws_s3_bucket.dev_media.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "dev_media" {
  bucket = aws_s3_bucket.dev_media.id

  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = var.dev_media_cors_origins
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

/*
 * dev.<도메인> 은 Vercel 을 가리키는 CNAME 이고, 그 대상의 CAA 가 Amazon 을 허용하지 않는다.
 * 하위 이름의 CAA 검사가 그 CNAME 을 따라가 ACM 발급이 CAA_ERROR 로 실패했다 (2026-10-15).
 * 이 이름에 직접 CAA 를 두면 검사가 여기서 멈춘다.
 */
resource "aws_route53_record" "dev_cdn_caa" {
  count = local.dev_cdn_host != "" ? 1 : 0

  zone_id = aws_route53_zone.main[0].zone_id
  name    = local.dev_cdn_host
  type    = "CAA"
  ttl     = 300
  records = ["0 issue \"amazon.com\""]
}

resource "aws_acm_certificate" "dev_cdn" {
  count    = local.dev_cdn_host != "" ? 1 : 0
  provider = aws.us_east_1

  domain_name       = local.dev_cdn_host
  validation_method = "DNS"

  depends_on = [aws_route53_record.dev_cdn_caa]

  lifecycle {
    create_before_destroy = true
  }
}

# 검증 레코드가 살아 있어야 ACM 자동 갱신이 된다
resource "aws_route53_record" "dev_cdn_validation" {
  for_each = local.dev_cdn_host != "" ? {
    for o in aws_acm_certificate.dev_cdn[0].domain_validation_options : o.domain_name => o
  } : {}

  zone_id         = aws_route53_zone.main[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "dev_cdn" {
  count    = local.dev_cdn_host != "" ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.dev_cdn[0].arn
  validation_record_fqdns = [for r in aws_route53_record.dev_cdn_validation : r.fqdn]
}

resource "aws_cloudfront_origin_access_control" "dev_media" {
  name                              = "${var.project}-dev-media"
  description                       = "read private dev bucket with signed requests"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "dev_media" {
  enabled = true
  comment = "${var.project} dev media"
  aliases = local.dev_cdn_host != "" ? [local.dev_cdn_host] : []

  origin {
    domain_name              = aws_s3_bucket.dev_media.bucket_regional_domain_name
    origin_id                = "media"
    origin_access_control_id = aws_cloudfront_origin_access_control.dev_media.id
  }

  default_cache_behavior {
    target_origin_id       = "media"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    # AWS 관리형 CachingOptimized. 운영과 같다
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  price_class = "PriceClass_200"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # sni-only 다. dedicated IP 방식은 월 600 USD 가 붙는다
  viewer_certificate {
    cloudfront_default_certificate = local.dev_cdn_host == ""
    acm_certificate_arn            = local.dev_cdn_host != "" ? aws_acm_certificate_validation.dev_cdn[0].certificate_arn : null
    ssl_support_method             = local.dev_cdn_host != "" ? "sni-only" : null
    minimum_protocol_version       = local.dev_cdn_host != "" ? "TLSv1.2_2021" : null
  }

  tags = {
    Name = "${var.project}-dev-media"
  }
}

# 이 배포의 서명만 허용한다. 다른 경로로는 버킷을 읽을 수 없다.
data "aws_iam_policy_document" "dev_media_bucket" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.dev_media.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.dev_media.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "dev_media" {
  bucket = aws_s3_bucket.dev_media.id
  policy = data.aws_iam_policy_document.dev_media_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.dev_media]
}

resource "aws_route53_record" "dev_cdn" {
  for_each = local.dev_cdn_host != "" ? toset(["A"]) : toset([])

  zone_id = aws_route53_zone.main[0].zone_id
  name    = local.dev_cdn_host
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.dev_media.domain_name
    zone_id                = aws_cloudfront_distribution.dev_media.hosted_zone_id
    evaluate_target_health = false
  }
}

output "dev_media_bucket" {
  description = "개발 이미지 버킷. dev/ 가 앱의 S3_MEDIA_BUCKET 으로 넘긴다"
  value       = aws_s3_bucket.dev_media.bucket
}

output "dev_cdn_url" {
  description = "개발 이미지 주소. dev/ 가 앱의 CDN_BASE_URL 로 넘긴다"
  value       = local.dev_cdn_host != "" ? "https://${local.dev_cdn_host}" : "https://${aws_cloudfront_distribution.dev_media.domain_name}"
}

/*
 * 이미지 버킷은 비공개다. CloudFront + OAC 가 서빙한다 (이미지저장소 설계 6.2절).
 * 업로드는 presigned PUT 으로 S3 에 직접 가고, 조회는 CloudFront 를 거친다.
 *
 * 버킷을 공개하지 않는 것이 요점이다.
 * 공개하면 키 구조가 드러나고 나중에 서명 URL 로 좁힐 수도 없다.
 */

resource "aws_s3_bucket" "media" {
  bucket = local.media_bucket

  tags = {
    Name = local.media_bucket
  }

  lifecycle {
    prevent_destroy = true
  }
}

# 넷을 모두 켠다. 하나라도 빠지면 버킷 정책이나 ACL 로 공개될 여지가 남는다.
resource "aws_s3_bucket_public_access_block" "media" {
  bucket                  = aws_s3_bucket.media.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

/*
 * presigned PUT 이 브라우저에서 직접 온다.
 * CORS 가 없으면 업로드가 브라우저 단에서 막힌다.
 */
resource "aws_s3_bucket_cors_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = var.media_cors_origins
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

resource "aws_cloudfront_origin_access_control" "media" {
  name                              = "${var.project}-media"
  description                       = "read private bucket with signed requests"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "media" {
  enabled = true
  comment = "${var.project} media"

  origin {
    domain_name              = aws_s3_bucket.media.bucket_regional_domain_name
    origin_id                = "media"
    origin_access_control_id = aws_cloudfront_origin_access_control.media.id
  }

  /*
   * 경로를 그대로 객체 key 로 오리진에 질의한다. 변환하지 않는다.
   * 원본만 저장하고 리사이징을 하지 않으므로 캐시 키에 넣을 것이 경로뿐이다.
   */
  default_cache_behavior {
    target_origin_id       = "media"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    # AWS 관리형 CachingOptimized. 직접 정의하면 관리 대상만 늘어난다.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # 무료 구간이 월 1TB 다. 가장 싼 등급으로도 넘길 일이 없다.
  price_class = "PriceClass_200"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "${var.project}-media"
  }
}

# 이 배포의 서명만 허용한다. 다른 경로로는 버킷을 읽을 수 없다.
data "aws_iam_policy_document" "media_bucket" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.media.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.media.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "media" {
  bucket = aws_s3_bucket.media.id
  policy = data.aws_iam_policy_document.media_bucket.json

  # 정책이 공개 판정을 받으면 block_public_policy 가 거부한다. 순서를 고정한다.
  depends_on = [aws_s3_bucket_public_access_block.media]
}

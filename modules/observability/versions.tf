/*
 * us-east-1 별칭은 부르는 쪽이 넘긴다.
 * CloudFront 인증서와 Route 53 헬스체크 알람이 그 리전에만 있다.
 */
terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.0"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

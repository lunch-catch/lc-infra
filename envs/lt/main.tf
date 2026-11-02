/*
 * 운영(envs/prod)과 같은 모듈을 부른다. 다른 것은 셋이다.
 *
 *   도메인 없음        ALB 주소로 HTTP 만 받는다. 인증서, DNS 레코드, 외부 감시가 생기지 않는다
 *   삭제 보호 없음     RDS, ALB, 모니터링, S3, ECR 을 바로 지울 수 있다. 파괴 가드도 두지 않는다
 *   자동 정리          cleanup.tf 가 정한 시각에 돈이 드는 것을 AWS 가 스스로 지운다
 *
 * 운영 모듈이 바뀌면 git pull 만으로 이 환경에도 들어간다.
 */

module "network" {
  source = "../../modules/network"

  project             = var.project
  region              = var.region
  grafana_alb_enabled = false
  duckdns_enabled     = false
}

module "data" {
  source = "../../modules/data"

  project                 = var.project
  azs                     = module.network.azs
  private_subnet_ids      = module.network.private_subnet_ids
  db_security_group_id    = module.network.security_group_ids["db"]
  cache_security_group_id = module.network.security_group_ids["cache"]
  deletion_protection     = false

  /*
   * 프리 티어 무료 플랜 계정은 자동 백업 보존 기간 7일(모듈 기본값)로는 RDS 를 만들지 못한다 (#76). 운영도 무료 플랜이던 동안 같은 이유로 1을 썼다.
   *   FreeTierRestrictionError: The specified backup retention period exceeds the maximum available to free tier customers.
   * 팀원 계정은 대부분 갓 만든 무료 플랜이다. 시험이 끝나면 지우는 환경이라 7일 보존이 필요 없어 어느 플랜에서나 1로 둔다.
   */
  db_backup_retention_days = 1
}

module "edge" {
  source = "../../modules/edge"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project               = var.project
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  alb_security_group_id = module.network.security_group_ids["alb"]
  deletion_protection   = false
  domain_name           = ""
  grafana_alb_enabled   = false
  media_bucket_name     = var.media_bucket_name
}

module "compute" {
  source = "../../modules/compute"

  project             = var.project
  region              = var.region
  public_subnet_ids   = module.network.public_subnet_ids
  private_subnet_ids  = module.network.private_subnet_ids
  security_group_ids  = module.network.security_group_ids
  deletion_protection = false

  alb_dns_name                = module.edge.alb_dns_name
  alb_arn_suffix              = module.edge.alb_arn_suffix
  app_target_group_arn        = module.edge.app_target_group_arn
  app_target_group_arn_suffix = module.edge.app_target_group_arn_suffix
  liveness_target_group_arn   = module.edge.liveness_target_group_arn
  grafana_alb_enabled         = false
  grafana_host                = module.edge.grafana_host
  domain_enabled              = false
  cdn_domain                  = module.edge.cdn_domain
  media_bucket                = module.edge.media_bucket

  db_address     = module.data.db_address
  db_name        = module.data.db_name
  db_username    = module.data.db_username
  cache_endpoint = module.data.cache_endpoint

  app_image_repository = var.app_image_repository
  load_test_enabled    = var.load_test_enabled
  profiling_enabled    = true
  tracing_enabled      = true
}

module "observability" {
  source = "../../modules/observability"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project                     = var.project
  monitoring_instance_id      = module.compute.monitoring_instance_id
  batch_asg_name              = module.compute.batch_asg_name
  alb_arn_suffix              = module.edge.alb_arn_suffix
  app_target_group_arn_suffix = module.edge.app_target_group_arn_suffix
  db_identifier               = module.data.db_identifier
  domain_enabled              = false
  alert_email                 = var.alert_email
  monthly_budget_usd          = var.monthly_budget_usd
}

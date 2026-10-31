/*
 * 운영 환경이다. 모듈을 조립만 한다. 리소스 정의는 modules/ 에 있다.
 *
 *   network         VPC, 서브넷, NAT, 엔드포인트, 보안 그룹
 *   data            RDS, ElastiCache
 *   edge            ALB, 인증서, DNS 레코드, 이미지 버킷과 CloudFront
 *   compute         시작 템플릿, 앱과 배치 ASG, 모니터링과 부하 생성기, ECR, IAM, 런타임 SSM 값
 *   observability   CloudWatch 알람, SNS, 예산
 *
 * 부하 시험 환경(envs/lt)이 같은 모듈을 다른 값으로 부른다.
 */

locals {
  has_domain = var.domain_name != ""

  /*
   * Grafana 를 ALB 에 붙이는 조건이다. network, edge, compute 가 같은 판단을 따라야 해서 여기서 한 번만 계산한다.
   * OIDC 인증 액션은 HTTPS 리스너에만 붙일 수 있어 도메인이 전제다.
   * 클라이언트 ID 가 없으면 인증 없이 노출하게 되므로 그때도 붙이지 않는다.
   */
  grafana_alb_enabled = local.has_domain && var.grafana_oidc_client_id != ""
}

/*
 * 운영을 통째로 지우는 사고를 plan 단계에서 막는다 (INF-18).
 *
 * prevent_destroy 는 변수로 바꿀 수 없어 모듈 안에 두면 부하 시험 환경까지 묶인다.
 * 그래서 모듈 안의 리소스에는 AWS 쪽 삭제 보호(var.deletion_protection)만 걸고, 이 가드는 운영 루트에만 둔다.
 * prevent_destroy 가 걸린 리소스가 하나라도 파괴 계획에 들면 terraform destroy 전체가 거부된다.
 *
 * 걷어내는 것은 destroy.sh 뿐이다. 코드를 고치지 않고 상태에서만 뺀다 (terraform state rm).
 * 다음 apply 가 다시 만든다.
 */
resource "terraform_data" "destroy_guard" {
  lifecycle {
    prevent_destroy = true
  }
}

module "network" {
  source = "../../modules/network"

  project                     = var.project
  region                      = var.region
  grafana_alb_enabled         = local.grafana_alb_enabled
  duckdns_enabled             = var.duckdns_hostname != ""
  grafana_https_allowed_cidrs = var.grafana_https_allowed_cidrs
}

module "data" {
  source = "../../modules/data"

  project                 = var.project
  azs                     = module.network.azs
  private_subnet_ids      = module.network.private_subnet_ids
  db_security_group_id    = module.network.security_group_ids["db"]
  cache_security_group_id = module.network.security_group_ids["cache"]
  deletion_protection     = var.deletion_protection

  db_instance_class        = var.db_instance_class
  db_multi_az              = var.db_multi_az
  db_backup_retention_days = var.db_backup_retention_days
  db_backup_window         = var.db_backup_window
  db_maintenance_window    = var.db_maintenance_window
  cache_node_type          = var.cache_node_type
}

module "edge" {
  source = "../../modules/edge"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project                = var.project
  vpc_id                 = module.network.vpc_id
  public_subnet_ids      = module.network.public_subnet_ids
  alb_security_group_id  = module.network.security_group_ids["alb"]
  deletion_protection    = var.deletion_protection
  domain_name            = var.domain_name
  grafana_alb_enabled    = local.grafana_alb_enabled
  grafana_oidc_client_id = var.grafana_oidc_client_id
  media_bucket_name      = var.media_bucket_name
}

module "compute" {
  source = "../../modules/compute"

  project             = var.project
  region              = var.region
  public_subnet_ids   = module.network.public_subnet_ids
  private_subnet_ids  = module.network.private_subnet_ids
  security_group_ids  = module.network.security_group_ids
  deletion_protection = var.deletion_protection

  alb_dns_name                = module.edge.alb_dns_name
  alb_arn_suffix              = module.edge.alb_arn_suffix
  app_target_group_arn        = module.edge.app_target_group_arn
  app_target_group_arn_suffix = module.edge.app_target_group_arn_suffix
  liveness_target_group_arn   = module.edge.liveness_target_group_arn
  grafana_alb_enabled         = local.grafana_alb_enabled
  grafana_target_group_arn    = module.edge.grafana_target_group_arn
  grafana_host                = module.edge.grafana_host
  domain_enabled              = local.has_domain
  duckdns_hostname            = var.duckdns_hostname
  cdn_domain                  = module.edge.cdn_domain
  media_bucket                = module.edge.media_bucket

  db_address     = module.data.db_address
  db_name        = module.data.db_name
  db_username    = module.data.db_username
  cache_endpoint = module.data.cache_endpoint

  instance_types                   = var.instance_types
  app_target_requests_per_instance = var.app_target_requests_per_instance
  app_image_repository             = var.app_image_repository
  load_test_enabled                = var.load_test_enabled
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
  domain_enabled              = local.has_domain
  certificate_arn             = module.edge.certificate_arn
  endpoint_health_check_id    = module.edge.endpoint_health_check_id
  alert_email                 = var.alert_email
  monthly_budget_usd          = var.monthly_budget_usd
}

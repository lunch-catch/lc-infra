output "alb_dns_name" {
  description = "앱 주소. member-env.sh 가 기동을 기다릴 때 부른다"
  value       = module.edge.alb_dns_name
}

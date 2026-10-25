# AWS 아키텍처

2026-10-25 기준 실제 AWS 리소스와 이 저장소의 Terraform 에 맞춰 그린 그림이다. 원본은 같은 폴더의 `.drawio` 다.

## 운영

![운영 AWS 아키텍처](aws-prod.png)

| 구역 | 구성 |
|---|---|
| 네트워크 | VPC 10.0.0.0/16, AZ 2a, 2c. 퍼블릭 10.0.1.0/24, 10.0.2.0/24 에 NAT Gateway 를 AZ 마다 1대 둔다. 프라이빗 10.0.11.0/24, 10.0.12.0/24 |
| 진입 | Route53 -> ALB -> API 서버. 프론트는 Vercel, 이미지는 CloudFront -> S3 (OAC) |
| 앱 | API 서버, 배치 서버 t3.small 을 AZ 마다 1대씩 각각 Auto Scaling Group 으로 둔다. 이미지는 GitHub Actions 가 ECR 에 올리고 서버가 NAT 를 거쳐 받는다 |
| 데이터 | RDS MySQL 8.4 db.t4g.small Multi-AZ (2026-10-26 06:00 에 micro 에서 올렸다. Primary, Standby 는 장애 조치 때 서로 바뀐다), ElastiCache Valkey 9.0 Primary 2a, Replica 2c |
| 외부 서비스 | Bedrock (ap-northeast-1) 로 템플릿을 만들고 Rekognition 으로 포스터 이미지 문자를 검수한다 |
| 관측 | 모니터링 EC2 (t4g.small) 에서 Grafana, Prometheus, Loki, Alertmanager 가 돈다. Alertmanager -> Slack. CloudWatch 알람 -> SNS 메일 |

## 개발

![개발 AWS 아키텍처](aws-dev.png)

| 구역 | 구성 |
|---|---|
| 네트워크 | Dev VPC 10.10.0.0/16, 단일 AZ 2a, 퍼블릭 서브넷 10.10.1.0/24 |
| 서버 | Dev EC2 (t3.medium) 한 대에서 caddy, app-blue, app-green, MySQL, Valkey, Grafana, Prometheus 컨테이너가 돈다 |
| 배포 | 배포마다 쉬고 있는 쪽(blue 또는 green)을 띄우고 caddy 가 그쪽으로 넘긴다. 이미지는 ECR (`lunchcatch-dev`) 에서 받는다 |
| 로그 | 앱 로그는 CloudWatch Logs `/lunchcatch/dev/app` (30일) |

## 고치는 법

1. `.drawio` 를 draw.io 에서 연다.
2. 고친 뒤 PNG 로 내보낸다. 내보내기 창의 Border Width 를 50 정도로 두어 가장자리에 여백을 준다.
3. `.drawio` 와 `.png` 를 함께 커밋한다. 둘이 어긋나면 그림이 실제와 다른지 원본이 다른지 알 수 없다.

인스턴스 클래스, 서브넷, 리소스를 바꾸는 PR 은 이 그림도 함께 고친다.

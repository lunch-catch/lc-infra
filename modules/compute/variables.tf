variable "project" {
  description = "모든 리소스 이름과 SSM 경로의 접두사"
  type        = string
}

variable "region" {
  description = "AWS 리전"
  type        = string
}

variable "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID. 키는 논리 AZ 이름이다. 부하 생성기와 DuckDNS 경로의 모니터링이 쓴다"
  type        = map(string)
}

variable "private_subnet_ids" {
  description = "프라이빗 서브넷 ID. 키는 논리 AZ 이름이다. 앱, 배치, 모니터링이 쓴다"
  type        = map(string)
}

variable "security_group_ids" {
  description = "역할별 보안 그룹 ID. app, batch, mon, loadtest 키를 쓴다"
  type        = map(string)
}

variable "alb_dns_name" {
  description = "부하 생성기가 부를 ALB 주소"
  type        = string
}

variable "alb_arn_suffix" {
  description = "스케일링 정책이 볼 ALB 식별자"
  type        = string
}

variable "app_target_group_arn" {
  description = "앱 ASG 를 붙일 대상 그룹"
  type        = string
}

variable "app_target_group_arn_suffix" {
  description = "스케일링 정책이 볼 앱 대상 그룹 식별자"
  type        = string
}

variable "liveness_target_group_arn" {
  description = "앱 ASG 를 함께 붙일 liveness 대상 그룹"
  type        = string
}

variable "grafana_alb_enabled" {
  description = "Grafana 를 ALB 뒤에 붙이는지 여부. edge 모듈과 같은 값을 넘긴다"
  type        = bool
}

variable "grafana_target_group_arn" {
  description = "모니터링을 붙일 Grafana 대상 그룹. grafana_alb_enabled 가 false 면 null 이다"
  type        = string
  default     = null
}

variable "grafana_host" {
  description = "Grafana 호스트 이름. ALB 경로일 때 ROOT_URL 이 된다"
  type        = string
}

/*
 * 쿠키의 Secure 속성이 이것을 따른다.
 * HTTPS 가 없으면 브라우저가 쿠키를 버린다.
 */
variable "domain_enabled" {
  description = "서비스 도메인과 HTTPS 리스너가 있는지 여부"
  type        = bool
}

/*
 * 도메인을 사기 전까지 쓰는 임시 경로다. 비우면 아무것도 만들지 않는다.
 *
 * ALB 를 거치지 않는다. 모니터링 인스턴스의 Caddy 가 직접 TLS 를 종료하고
 * Let's Encrypt 에서 인증서를 받는다. ACM 은 도메인 소유 검증이 필요해 쓸 수 없다.
 *
 * domain_name 이 생기면 이 값을 비운다. 두 경로를 동시에 켜지 않는다.
 */
variable "duckdns_hostname" {
  description = "DuckDNS 호스트명. 예: lunchcatch.duckdns.org"
  type        = string
  nullable    = false
  default     = ""
}

variable "db_address" {
  description = "SSM db-endpoint 의 초기값"
  type        = string
}

variable "db_name" {
  description = "데이터베이스 이름. 앱의 접속 URL 에 들어간다"
  type        = string
}

variable "db_username" {
  description = "DB 마스터 사용자. 앱과 mysqld-exporter 가 쓴다"
  type        = string
}

variable "cache_endpoint" {
  description = "SSM cache-endpoint 의 초기값"
  type        = string
}

variable "cdn_domain" {
  description = "SSM cdn-domain 의 초기값"
  type        = string
}

variable "media_bucket" {
  description = "앱이 presigned URL 을 발급할 이미지 버킷 이름"
  type        = string
}

/*
 * AWS 쪽 삭제 보호다. 모니터링 인스턴스의 종료 보호와 루트 볼륨 보존, ECR 의 비우기 거부가 이것을 따른다.
 * 운영은 켜 두고 destroy.sh 가 파괴 직전에만 끈다. 부하 시험 환경은 꺼 둔다.
 */
variable "deletion_protection" {
  description = "모니터링 종료 보호와 볼륨 보존, ECR 비우기 거부 여부"
  type        = bool
}

/*
 * 앱을 늘리는 기준이다. 대상당 분당 요청 수가 이 값을 넘으면 인스턴스를 더 띄운다.
 *
 * CPU 를 쓰지 않는다. 일반 경로도 요청 스레드가 DB 응답을 기다리며 블록되므로,
 * 톰캣 스레드 200 개가 다 잠겨 포화된 상태에서도 CPU 는 낮게 유지될 수 있다.
 * 도착률은 병목이 어디든 부하를 그대로 반영한다.
 *
 * 시작값이고 실측이 아니다. 한 대가 견디는 도착률을 부하 시험에서 잰 뒤 그 값에서 역산한다.
 *
 * 늘려도 DB 는 한 대다. 앱을 3 대로 올려 처리량이 안 늘면 병목이 DB 이므로
 * 그때는 확장이 아니라 쿼리나 등급을 봐야 한다.
 */
variable "app_target_requests_per_instance" {
  description = "앱 ASG 확장 기준. 대상당 분당 요청 수"
  type        = number
  nullable    = false
  default     = 6000
}

/*
 * 역할별 인스턴스 타입. 기술 스택 확정 문서 2.6절.
 *
 * batch 는 app 과 같은 아키텍처여야 한다. 같은 컨테이너 이미지를 batch 프로필로 띄우기 때문이다.
 * t4g 계열(ARM64)로 두었을 때 배포 이미지가 amd64 라 컨테이너가
 * "exec /opt/java/openjdk/bin/java: exec format error" 로 계속 재시작했다.
 * 빌드가 러너(x86_64)에서 단일 아키텍처로 나오므로 app 이 t3 인 한 batch 도 t3 여야 한다.
 *
 * batch 를 t3.micro 에서 t3.small 로 올렸다 (2026-08-30). 1 GB 로는 모자랐다.
 *
 * 실측이 있다. 배포가 배치를 재시작한 직후 여유 메모리가 910 MiB 중 103 MiB(11%)까지
 * 떨어졌고, 커널이 SSM 에이전트와 node-exporter 와 cadvisor 를 죽였다.
 * JVM 만 살아남아 up=1 이 유지되는 바람에 겉으로는 정상으로 보였고,
 * SSM 명령이 Undeliverable 로 떨어지고 나서야 드러났다.
 *
 * 1 GB 에 다음이 함께 올라간다. 애초에 맞지 않는다.
 *
 *   JVM             heap max 616 MiB (Eden 170 + Survivor 21 + Tenured 425)
 *   dockerd         컨테이너 넷을 관리한다
 *   cadvisor        컨테이너 지표를 읽느라 자체 사용이 적지 않다
 *   node-exporter   가볍다
 *   SSM 에이전트     이것이 죽으면 원격 진단 자체가 막힌다
 *
 * 월 9.49 에서 18.98 USD 가 된다. t3.micro 는 프리 티어 750시간 대상이라 사실상 공짜였고
 * t3.small 은 아니므로 증가분이 그대로 크레딧에서 나간다.
 *
 * 메모리 대신 JVM 힙을 조이는 선택지도 있었다. -Xmx384m 이면 1 GB 에 들어간다.
 * 그러나 배치가 대량 쓰기를 도는 순간 GC 압박이 그대로 처리 시간이 되고,
 * 그때 RDS 페일오버가 겹치면 열려 있던 트랜잭션이 길어져 RTO 2분을 넘긴다.
 * 스케줄러 한 대에 9.49 USD 를 아끼려고 만들 위험이 아니다.
 *
 * monitoring 은 관계없다. 자기 이미지를 따로 받고 전부 멀티아키를 제공한다.
 *
 * load_test 는 x86 이다. k6 는 멀티아키를 제공하므로 제약은 아니고 나머지와 맞춰 둔 것이다.
 *
 * m7i-flex.large 는 고른 것이 아니라 남은 것이다 (2026-08-30).
 *
 * 확정값은 m7i.xlarge (4 vCPU / 16 GB) 였고 실측에서 나온 값이었다. 그런데 이 계정이
 * 프리 티어라 RunInstances 가 거부한다. InvalidParameterCombination 으로 떨어진다.
 * 띄울 수 있는 것이 여섯뿐이고 그중 메모리가 가장 큰 것이 m7i-flex.large 8 GB 다.
 *
 * 목록은 describe-instance-types 의 free-tier-eligible 필터로 얻는다. 2026-09-27 조회다.
 *
 *   m7i-flex.large  2 vCPU  8 GiB   <- 이것뿐
 *   c7i-flex.large  2 vCPU  4 GiB
 *   t8i.small / t3.small / t4g.small   2 GiB
 *   t8i.micro / t3.micro / t4g.micro   1 GiB
 *
 * r 계열(2 vCPU / 16 GiB)을 쓰려고 2026-09-27 에 시도했다가 되돌렸다. RunInstances 가
 * InvalidParameterCombination 으로 거부한다. vCPU 가 2 여도 프리 티어 목록에 없으면 안 된다.
 *
 * dry-run 으로 확인하면 안 된다. run-instances --dry-run 은 권한과 파라미터 형식만 보고
 * DryRunOperation 을 돌려준다. 계정 등급 제한은 실제 호출에서만 걸리므로, r7i.large 와
 * r6i.large 와 r5.large 가 모두 dry-run 을 통과하고 실제로는 셋 다 거부된다.
 *
 * 그래서 아래 둘을 알면서 어긴다.
 *
 * 하나. 메모리가 모자란다. 2026-08-28 에 5,076 MiB 를 재고 8 GB 의 63% 라고 적었는데
 * 그것은 60초 램프 끝까지의 값이었다. 회차는 그 뒤로 30초를 더 도는데 그 구간에 메모리가
 * 계속 올라 2026-09-26 실측 최고점이 7,667 MB 다. 오류 응답이 늘면 MemTotal 7,776 MiB 를
 * 넘긴다.
 *
 * 판정을 받은 VU 가 sleep(1) 로 계속 돌아서 반복이 90만 회 쌓이는 것이 원인이다. 곡선과
 * 반복당 비용은 docs/deploy/README.md 의 실측표 아래에 있다.
 *
 * 둘. flex 를 안 쓰기로 했던 결정을 어긴다. 측정 안정성 때문이었던 결정이다.
 *
 * 크레딧 이야기가 아니다. m7i-flex 는 BurstablePerformanceSupported 가 false 라
 * T 계열과 달리 크레딧을 쓰지 않는다. 베이스라인 위에서 24시간 중 95% 를 풀 성능으로
 * 보장하는 방식이다. describe-instance-credit-specifications 가 standard 를 돌려주지만
 * 버스터블이 아닌 타입에는 의미 없는 잔여 필드다.
 *
 * 그래서 오히려 진단이 어렵다. T 계열이면 회차 간 차이가 났을 때 CPUCreditBalance 를 보고
 * 크레딧이 말랐는지 알 수 있는데, flex 에는 그런 지표가 없다. 원인 없이 숫자만 흔들린다.
 * 대책은 같은 회차를 두 번 이상 돌려 재현되는지 보는 것뿐이다.
 *
 * CPU 는 원래 실측하지 못했고 이제 4 vCPU 가 아니라 2 vCPU 다.
 *
 * 첫 회차에서 셋을 본다. dropped_iterations 가 0 인가, free -m 에 스왑이 안 생기는가,
 * CPU 가 100% 에 안 붙는가. 하나라도 어긋나면 이 인스턴스의 한계를 잰 것이지
 * 앱의 한계를 잰 것이 아니다. 그때는 부하를 여러 대로 나눠야 한다.
 */
variable "instance_types" {
  description = "역할별 인스턴스 타입. 기술 스택 확정 문서 2.6절"
  type        = map(string)
  nullable    = false

  default = {
    app        = "t3.small"
    monitoring = "t4g.small"
    batch      = "t3.small"
    load_test  = "m7i-flex.large"
  }
}

variable "github_org" {
  description = "GitHub 조직. OIDC 신뢰 조건과 저장소 clone 경로에 쓴다"
  type        = string
  nullable    = false
  default     = "lunch-catch"
}

variable "github_backend_repo" {
  description = "배포를 트리거하는 저장소. 이 저장소의 main 브랜치만 배포 역할을 맡을 수 있다"
  type        = string
  nullable    = false
  default     = "lc-backend"
}

variable "github_infra_repo" {
  description = "terraform plan 을 돌리는 저장소"
  type        = string
  nullable    = false
  default     = "lc-infra"
}

/*
 * 부하 생성기의 node_exporter 버전이다.
 *
 * observability/compose.yaml 이 쓰는 prom/node-exporter 태그와 같은 값을 둔다. 다른 인스턴스는
 * 도커로 돌리고 생성기는 바이너리로 돌리는데, 버전이 갈리면 같은 지표가 다른 이름으로 나올 수
 * 있어 회차 간 비교가 흔들린다.
 *
 * 올릴 때는 compose.yaml 과 함께 올린다.
 */
variable "node_exporter_version" {
  description = "부하 생성기에 설치할 node_exporter 버전. compose.yaml 과 같은 값을 둔다"
  type        = string
  nullable    = false
  default     = "1.9.1"
}

/*
 * k6 버전을 박는다. 최신을 깔면 안 된다.
 *
 * VU 당 메모리 실측(2026-08-28, 2만 VU 에 5.0 GB)이 1.7.1 기준이고, m7i.xlarge 를
 * 고른 근거가 그 수치다. 런타임이 바뀌면 같은 스크립트가 다른 메모리를 쓴다.
 *
 * 부하 시험은 회차 간 숫자를 비교하는 일이라 도구가 고정되어야 한다.
 * 도구가 바뀌면 이번 회차가 나빠진 것이 앱 탓인지 k6 탓인지 못 가린다.
 *
 * 올릴 때는 이 값만 바꾸고 메모리를 다시 잰 뒤 deploy/README 의 실측표를 갱신한다.
 */
variable "k6_version" {
  description = "부하 생성기에 설치할 k6 버전"
  type        = string
  nullable    = false
  default     = "1.7.1"
}

variable "load_test_enabled" {
  description = "부하 생성 인스턴스를 띄울지 여부"
  type        = bool
  nullable    = false
  default     = false
}

/*
 * 운영 프론트 주소다. 운영 API 의 CORS 허용 출처가 된다 (프론트엔드 배포 문서 6장).
 * www 는 루트로 리다이렉트해 실제로 API 를 부르지 않지만 리다이렉트 전 요청을 막지 않으려고 둔다.
 * 개발 프론트(dev.)는 넣지 않는다. 개발 화면은 개발 API 만 부른다.
 */
variable "frontend_origins" {
  description = "운영 API 가 받는 출처"
  type        = list(string)
  nullable    = false
  default = [
    "https://lunchcatch.com",
    "https://www.lunchcatch.com",
    "https://owner.lunchcatch.com",
    "https://admin.lunchcatch.com",
  ]
}

/*
 * 카카오가 인가 코드를 돌려줄 주소다. 사용자 앱의 /oauth/callback (KakaoCallbackPage) 이다.
 * 카카오 개발자 콘솔의 Redirect URI 목록에 같은 값이 있어야 한다. 없으면 카카오가 KOE006 으로 거절한다.
 */
variable "kakao_redirect_uri" {
  description = "카카오 로그인 리다이렉트 주소"
  type        = string
  nullable    = false
  default     = "https://lunchcatch.com/oauth/callback"
}

/*
 * 관리자 템플릿 생성이 부르는 Bedrock 모델이다 (LLM 문서 2.1절).
 * 서버 역할의 호출 권한도 이 값으로 좁힌다. 모델을 바꾸면 이 값만 고친다.
 */
variable "bedrock_model_id" {
  description = "Bedrock 모델 ID 또는 추론 프로필 ID"
  type        = string
  nullable    = false
  default     = "jp.anthropic.claude-sonnet-4-6"
}

/*
 * 도쿄의 jp 추론 프로필로 부른다.
 * 요청이 일본(도쿄, 오사카) 안에서만 돈다 (LLM 문서 2.1절).
 * 인프라 리전과 따로 둔다.
 */
variable "bedrock_region" {
  description = "Bedrock 을 부르는 리전"
  type        = string
  nullable    = false
  default     = "ap-northeast-1"
}

/*
 * 앱 이미지를 받을 저장소다. 비우면 이 계정의 ECR(var.project)을 쓴다. 운영은 비운다.
 *
 * 팀원 계정의 부하 시험 환경(scripts/member-env.sh, #11)이 우리 계정의 개발 ECR 을 가리킬 때 쓴다.
 * 운영 ECR 은 운영을 내리면 함께 지워져 그 계정 밖에서 기댈 수 없다.
 */
variable "app_image_repository" {
  description = "앱 이미지 저장소 주소. 예: <계정 ID>.dkr.ecr.ap-northeast-2.amazonaws.com/lunchcatch-dev"
  type        = string
  nullable    = false
  default     = ""
}

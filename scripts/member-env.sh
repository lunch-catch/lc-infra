#!/usr/bin/env bash
#
# 팀원이 자기 AWS 계정에 운영과 같은 인프라를 한 벌 띄워 부하 시험을 한다 (#11).
# 문서: docs/system-design/런치캐치_팀원_부하시험환경.md
#
#   AWS_PROFILE=me ./scripts/member-env.sh up              띄운다. 4시간 뒤 AWS 가 스스로 지운다
#   AWS_PROFILE=me ./scripts/member-env.sh up --sha <sha>  lc-backend 의 그 커밋 이미지로 띄운다
#   AWS_PROFILE=me ./scripts/member-env.sh status          떠 있는 것과 정리 시각
#   AWS_PROFILE=me ./scripts/member-env.sh down            전부 지운다
#
# MEMBER_ALERT_EMAIL 을 주면 예산 알림과 경보를 그 메일로 받는다. 처음 받는 확인 메일의 링크를 누른다.
#
# up 을 다시 부르면 바뀐 코드만 반영하고 정리 시각을 지금부터 다시 센다.
#
# 운영과 같은 모듈(modules/)을 부하 시험 루트(envs/lt)로 부른다. 팀원 환경에 맞는 차이(도메인 없음,
# 삭제 보호 해제, 자동 정리)는 그 루트가 값으로 갖는다. 그래서 운영 코드가 바뀌면
# git pull 하고 up 하는 것만으로 팀원 환경에도 들어간다.
#
# 계정마다 상태 버킷과 변수 파일과 .terraform 이 다르다. 셋 다 ~/.lunchcatch-member/<계정> 아래에 둔다.
#
# 실행한 사람의 계정 하나만 쓴다. 다른 계정에 기대는 것이 없다 (#52).
# 앱 이미지는 lc-backend 가 develop 마다 올리는 GHCR 공개 패키지에서 로그인 없이 받는다.
#
# 접두사는 lunchcatch-lt 다. 같은 계정에 운영(lunchcatch)이 있어도 이름이 부딪히지 않는다.
# 다만 계정 한도와 관측(Prometheus 가 계정의 서버를 모두 찾는다)을 나눠 쓰므로 운영이 떠 있으면 멈춘다.
set -euo pipefail

CMD="${1:-}"
shift || true

PROJECT="lunchcatch-lt"
PROD_PROJECT="lunchcatch"
REGION="ap-northeast-2"
# lc-backend 의 이미지 공개 워크플로(.github/workflows/image.yml)가 develop 커밋마다 올린다
BACKEND_REPO="lunch-catch/lc-backend"
IMAGE_WORKFLOW="image.yml"
APP_IMAGE_REPOSITORY="ghcr.io/$BACKEND_REPO"
HOURS="${MEMBER_HOURS:-4}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) SHA="$2"; shift 2 ;;
    *) die "모르는 인자 $1" ;;
  esac
done

case "$CMD" in
  up|status|down) ;;
  *) sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

for c in aws terraform git curl; do
  command -v "$c" > /dev/null || die "$c 가 없다. docs/system-design/런치캐치_팀원_부하시험환경.md 의 준비를 본다"
done

[ -n "${AWS_PROFILE:-}${AWS_ACCESS_KEY_ID:-}" ] || die "AWS_PROFILE 을 준다. 자기 계정의 관리자 프로필이다. 예: AWS_PROFILE=me"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text) || die "자격 증명을 확인한다"
WORK="$HOME/.lunchcatch-member/$ACCOUNT-lt"
# 이 계정에 운영이 조금이라도 남아 있으면 띄우지 않는다. down 과 status 는 막지 않는다
if [ "$CMD" = "up" ]; then
  prod_db=$(aws rds describe-db-instances --db-instance-identifier "$PROD_PROJECT-db" \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2> /dev/null || true)
  # 개발 서버도 Project 태그가 lunchcatch 라 Role 로 뺀다
  prod_vms=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=$PROD_PROJECT" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "length(Reservations[].Instances[] | [?Tags[?Key=='Role'].Value | [0] != 'dev-server'])" --output text)
  [ -z "$prod_db" ] && [ "$prod_vms" = "0" ] \
    || die "이 계정에 운영이 떠 있다 (DB ${prod_db:-없음}, 서버 $prod_vms 대). 운영을 내린 뒤 띄운다 (./scripts/destroy.sh)"
fi
TF="$ROOT/envs/lt"
VARS="$WORK/member.tfvars"
# 같은 루트를 여러 계정에서 돌리므로 .terraform 을 계정마다 따로 둔다
export TF_DATA_DIR="$WORK/.terraform"

#
# 모듈화(#50) 전의 작업 사본이 남아 있으면 그 상태는 옛 주소를 쓴다. 새 코드로 up 하면 같은 이름을 다시 만들다 부딪힌다.
# 그때는 접두사가 계정마다 달랐다(lunchcatch 또는 lunchcatch-lt). 두 자리를 다 본다.
#
for old in "$HOME/.lunchcatch-member/$ACCOUNT:lunchcatch" "$HOME/.lunchcatch-member/$ACCOUNT-lt:lunchcatch-lt"; do
  dir="${old%%:*}"
  [ -d "$dir/terraform" ] || continue
  die "모듈화 전에 띄운 환경이 남아 있다. 옛 사본으로 먼저 지운다:
  terraform -chdir=$dir/terraform init -reconfigure -backend-config=bucket=tfstate-${old##*:}-$ACCOUNT -backend-config=key=member/terraform.tfstate -backend-config=region=$REGION
  terraform -chdir=$dir/terraform destroy
  rm -rf $dir/terraform $dir/observability"
done
STATE_BUCKET="tfstate-$PROJECT-$ACCOUNT"
export TF_IN_AUTOMATION=1
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

write_vars() {
  local expires=$1
  mkdir -p "$WORK"
  cat > "$VARS" <<EOF
# member-env.sh 가 만든다. 고치지 않는다
allowed_account_ids  = ["$ACCOUNT"]
alert_email          = "${MEMBER_ALERT_EMAIL:-}"
project              = "$PROJECT"
media_bucket_name    = "$PROJECT-media-$ACCOUNT"
app_image_repository = "$APP_IMAGE_REPOSITORY"
load_test_enabled    = true
monthly_budget_usd   = "50"
member_expires_at    = "$expires"
EOF
}

# 운영 모드를 한 줄로 보인다. 서버는 배포와 재부팅 때 SSM run-mode 를 읽어 프로필을 정한다
run_mode() {
  case "$(aws ssm get-parameter --name "/$PROJECT/run-mode" --query Parameter.Value --output text 2> /dev/null)" in
    live) echo "live (결제는 토스)" ;;
    *) echo "loadtest (부하 시험, 결제는 목)" ;;
  esac
}

tf_init() {
  terraform -chdir="$TF" init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="key=member/terraform.tfstate" \
    -backend-config="region=$REGION" > /dev/null
}

ensure_state_bucket() {
  if aws s3api head-bucket --bucket "$STATE_BUCKET" 2> /dev/null; then
    return
  fi
  log "   상태 버킷 $STATE_BUCKET 생성"
  aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=$REGION" > /dev/null
  aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-public-access-block --bucket "$STATE_BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
}

# 앱과 모니터링이 읽는 시크릿이다. 없는 것만 만든다. 운영 값이 아니라 시험용이다
ensure_secrets() {
  local db
  put() {
    aws ssm get-parameter --name "/$PROJECT/$1" > /dev/null 2>&1 && return 0
    aws ssm put-parameter --name "/$PROJECT/$1" --type SecureString --value "$2" > /dev/null
    log "   /$PROJECT/$1 생성"
  }
  db=$(aws ssm get-parameter --name "/$PROJECT/db-password" --with-decryption \
    --query Parameter.Value --output text 2> /dev/null || openssl rand -hex 16)
  put jwt-signing-key "$(openssl rand -base64 48)"
  put db-password "$db"
  put db-exporter-password "$db"
  put grafana-admin-password "$(openssl rand -hex 12)"
  # 저장소가 PUBLIC 이라 토큰 없이 받는다 (monitoring-user-data)
  put github-token none
  # 부하 시험 환경은 항상 loadtest 다. 결제는 토스 대신 앱 안의 목이 받는다 (lc-backend #715)
  aws ssm put-parameter --name "/$PROJECT/run-mode" --value loadtest --type String --overwrite > /dev/null
  for n in critical warning watchdog; do put "slack-webhook-$n" "https://hooks.slack.com/services/none"; done
  # 부하 시험은 카카오를 부르지 않는다. 기동만 되게 채운다
  put kakao-client-id none
  put kakao-client-secret none
  put kakao-app-id 0
  put kakao-admin-key none
  # 부하 시험은 결제를 부르지 않는다. 비어 있으면 앱이 뜨지 않아 자리만 채운다
  put toss-secret-key none
}

# 띄우기 전에 코드가 원격과 같은지 본다. 뒤처진 코드로 띄우면 운영 변경이 빠진다
check_fresh() {
  git -C "$ROOT" fetch -q origin main || die "git fetch 실패"
  local head main
  head=$(git -C "$ROOT" rev-parse HEAD)
  main=$(git -C "$ROOT" rev-parse origin/main)
  if [ "$head" != "$main" ] && [ "${MEMBER_ALLOW_STALE:-}" != "1" ]; then
    die "lc-infra 가 origin/main 과 다르다. git pull 한 뒤 다시 돈다 (일부러면 MEMBER_ALLOW_STALE=1)"
  fi
}

# 이미지 워크플로가 develop 에서 마지막으로 성공한 커밋이다. 그 커밋의 이미지는 GHCR 에 올라가 있다
latest_sha() {
  curl -fsS "https://api.github.com/repos/$BACKEND_REPO/actions/workflows/$IMAGE_WORKFLOW/runs?branch=develop&status=success&per_page=1" \
    | grep -o '"head_sha": *"[0-9a-f]\{40\}"' | head -1 | grep -o '[0-9a-f]\{40\}'
}

# 이미지 태그는 40자 SHA 다. 짧은 SHA 를 받으면 GitHub 에 물어 늘린다
full_sha() {
  [ ${#1} -eq 40 ] && { echo "$1"; return; }
  curl -fsS "https://api.github.com/repos/$BACKEND_REPO/commits/$1" \
    | grep -o '"sha": *"[0-9a-f]\{40\}"' | head -1 | grep -o '[0-9a-f]\{40\}'
}

# 공개 패키지는 익명 토큰으로 매니페스트를 볼 수 있다. 없는 태그로 띄우면 서버가 이미지를 못 받아 20분을 버린다
image_exists() {
  local token
  token=$(curl -fsS "https://ghcr.io/token?scope=repository:$BACKEND_REPO:pull" | grep -o '"token":"[^"]*"' | cut -d'"' -f4) || return 1
  curl -fsS -o /dev/null -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://ghcr.io/v2/$BACKEND_REPO/manifests/$1"
}

expires_at() {
  date -u -d "+$HOURS hours" +%Y-%m-%dT%H:%M:%S 2> /dev/null || date -u -v+"$HOURS"H +%Y-%m-%dT%H:%M:%S
}

case "$CMD" in
up)
  log "1. 준비 (계정 $ACCOUNT)"
  check_fresh
  if [ -n "$SHA" ]; then
    SHA=$(full_sha "$SHA") || die "lc-backend 에 그 커밋이 없다"
  else
    SHA=$(latest_sha) || die "lc-backend develop 에서 이미지를 올린 커밋을 못 찾았다. Actions 의 '이미지 공개' 실행을 본다"
  fi
  image_exists "$SHA" || die "ghcr.io/$BACKEND_REPO:$SHA 가 없다. 그 커밋의 '이미지 공개' 실행이 끝났는지 본다"
  ensure_state_bucket
  ensure_secrets
  EXPIRES=$(expires_at)
  write_vars "$EXPIRES"
  tf_init

  # 인스턴스가 뜨면서 이 값을 읽는다. 먼저 만들어 채워 두어야 첫 부팅부터 그 이미지로 뜬다
  log "2. 이미지 $SHA"
  terraform -chdir="$TF" apply -auto-approve -input=false -var-file="$VARS" -target=module.compute.aws_ssm_parameter.current_sha > /dev/null
  aws ssm put-parameter --name "/$PROJECT/current-sha" --type String --overwrite --value "$SHA" > /dev/null

  log "3. terraform apply (처음은 20분쯤 걸린다)"
  terraform -chdir="$TF" apply -auto-approve -input=false -var-file="$VARS"

  ALB=$(terraform -chdir="$TF" output -raw alb_dns_name)
  log "4. 앱 대기 http://$ALB"
  ok=""
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 5 "http://$ALB/v3/api-docs" > /dev/null 2>&1; then ok=1; break; fi
    sleep 10
  done
  [ -n "$ok" ] || log "   10분 안에 응답하지 않았다. status 와 앱 로그를 본다"

  LT=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Role,Values=load-test" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  cat <<EOF

완료. 자동 정리 $EXPIRES (UTC). 그 전에 끝나면 down 을 부른다.

  운영 모드   $(run_mode)
  앱          http://$ALB
  부하 생성기 aws ssm start-session --target $LT
  Grafana     $0 status 가 접속 방법을 보여 준다
EOF
  ;;

status)
  [ -f "$VARS" ] || die "이 계정에 띄운 적이 없다"
  tf_init
  printf '정리 시각(UTC) %s\n' "$(terraform -chdir="$TF" output -raw member_expires_at 2> /dev/null || echo 없음)"
  printf 'ALB           %s\n' "$(terraform -chdir="$TF" output -raw alb_dns_name 2> /dev/null || echo 없음)"
  printf '이미지        %s\n' "$(aws ssm get-parameter --name "/$PROJECT/current-sha" --query Parameter.Value --output text 2> /dev/null || echo 없음)"
  printf '운영 모드     %s\n' "$(run_mode)"
  printf '\n떠 있는 인스턴스\n'
  aws ec2 describe-instances --filters "Name=tag:Project,Values=$PROJECT" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,InstanceType]' --output text | sed 's/^/  /'
  MON=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  if [ "$MON" != "None" ]; then
    cat <<EOF

Grafana (창을 열어 둔 동안 http://localhost:13000, 사용자 admin)
  aws ssm start-session --target $MON --document-name AWS-StartPortForwardingSession --parameters portNumber=3000,localPortNumber=13000
  비밀번호: aws ssm get-parameter --name /$PROJECT/grafana-admin-password --with-decryption --query Parameter.Value --output text
EOF
  fi
  ;;

down)
  [ -f "$VARS" ] || die "이 계정에 띄운 적이 없다"
  log "1. terraform destroy"
  tf_init
  # 정리 시각은 상관없다. 마지막 up 이 남긴 변수 파일을 그대로 쓴다
  terraform -chdir="$TF" destroy -auto-approve -input=false -var-file="$VARS"
  # 이 환경 것만 센다. 우리 계정에는 운영 흔적과 개발 서버가 함께 있다
  log "2. 남은 것 ($PROJECT)"
  printf '  EC2 %s, RDS %s, ALB %s, NAT %s, EIP %s\n' \
    "$(aws ec2 describe-instances --filters "Name=tag:Project,Values=$PROJECT" 'Name=instance-state-name,Values=running,pending,stopping,stopped' --query 'length(Reservations[].Instances[])' --output text)" \
    "$(aws rds describe-db-instances --query "length(DBInstances[?DBInstanceIdentifier=='$PROJECT-db'])" --output text)" \
    "$(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?LoadBalancerName=='$PROJECT-alb'])" --output text)" \
    "$(aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending "Name=tag:Project,Values=$PROJECT" --query 'length(NatGateways)' --output text)" \
    "$(aws ec2 describe-addresses --filters "Name=tag:Project,Values=$PROJECT" --query 'length(Addresses)' --output text)"
  log "끝. 시크릿(SSM)과 상태 버킷은 다음 up 을 위해 남긴다. 돈은 들지 않는다"
  ;;
esac

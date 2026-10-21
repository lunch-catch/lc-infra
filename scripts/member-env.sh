#!/usr/bin/env bash
#
# 팀원이 자기 AWS 계정에 운영과 같은 인프라를 한 벌 띄워 부하 시험을 한다 (#11).
# 문서: docs/system-design/런치캐치_팀원_부하시험환경.md
#
#   AWS_PROFILE=me ./scripts/member-env.sh up              띄운다. 4시간 뒤 AWS 가 스스로 지운다
#   AWS_PROFILE=me ./scripts/member-env.sh up --sha <sha>  개발 ECR 의 그 커밋 이미지로 띄운다
#   AWS_PROFILE=me ./scripts/member-env.sh status          떠 있는 것과 정리 시각
#   AWS_PROFILE=me ./scripts/member-env.sh down            전부 지운다
#
# MEMBER_ALERT_EMAIL 을 주면 예산 알림과 경보를 그 메일로 받는다. 처음 받는 확인 메일의 링크를 누른다.
#
# up 을 다시 부르면 바뀐 코드만 반영하고 정리 시각을 지금부터 다시 센다.
#
# 운영 코드(terraform/)를 고치지 않고 그대로 쓴다. 매번 작업 사본에 복사한 뒤 팀원 환경에 맞는
# 차이(도메인 없음, 삭제 보호 해제, 자동 정리)만 사본에 얹는다. 그래서 운영 코드가 바뀌면
# git pull 하고 up 하는 것만으로 팀원 환경에도 들어간다.
#
# 우리 계정(762794225116)에서는 돌지 않는다. 운영과 이름이 같아 부딪힌다.
set -euo pipefail

CMD="${1:-}"
shift || true

PROJECT="lunchcatch"
REGION="ap-northeast-2"
OUR_ACCOUNT="762794225116"
APP_IMAGE_REPOSITORY="$OUR_ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$PROJECT-dev"
HOURS="${MEMBER_HOURS:-4}"
# 부하 시험 환경은 항상 loadtest 로 뜬다. 결제는 토스 대신 목이 받는다 (lc-backend #715)
EXTRA_PROFILES="loadtest"
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
  *) sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

for c in aws terraform git; do
  command -v "$c" > /dev/null || die "$c 가 없다. docs/system-design/런치캐치_팀원_부하시험환경.md 의 준비를 본다"
done

[ -n "${AWS_PROFILE:-}${AWS_ACCESS_KEY_ID:-}" ] || die "AWS_PROFILE 을 준다. 자기 계정의 관리자 프로필이다. 예: AWS_PROFILE=me"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text) || die "자격 증명을 확인한다"
[ "$ACCOUNT" != "$OUR_ACCOUNT" ] || die "우리 계정($OUR_ACCOUNT)이다. 운영과 부딪힌다. 자기 계정 프로필을 쓴다"

WORK="$HOME/.lunchcatch-member/$ACCOUNT"
TF="$WORK/terraform"
STATE_BUCKET="tfstate-$PROJECT-$ACCOUNT"
export TF_IN_AUTOMATION=1
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

# 작업 사본을 운영 코드에서 새로 만든다. 상태는 S3 에 있어 사본을 지워도 잃지 않는다.
prepare_copy() {
  mkdir -p "$WORK"
  rm -rf "$WORK/observability"
  mkdir -p "$TF"
  find "$TF" -maxdepth 1 -type f \( -name '*.tf' -o -name '*.tfvars' -o -name '*.hcl' \) -delete
  rm -rf "$TF/templates"
  cp "$ROOT"/terraform/*.tf "$ROOT/terraform/.terraform.lock.hcl" "$TF/"
  cp -R "$ROOT/terraform/templates" "$TF/templates"
  cp -R "$ROOT/observability" "$WORK/observability"
  cp "$ROOT/member/cleanup.tf" "$TF/member_cleanup.tf"

  # 시험 환경이라 지키지 않는다. destroy.sh 의 가드 해제와 같은 자리다
  local s
  for f in "$TF"/*.tf; do
    s=$(sed \
      -e 's/^\( *\)prevent_destroy = true$/\1prevent_destroy = false/' \
      -e 's/^\( *\)enable_deletion_protection = true$/\1enable_deletion_protection = false/' \
      -e 's/^\( *\)deletion_protection\( *\)= true$/\1deletion_protection\2= false/' \
      -e 's/^\( *\)skip_final_snapshot\( *\)= false$/\1skip_final_snapshot\2= true/' \
      -e 's/^\( *\)delete_on_termination\( *\)= false$/\1delete_on_termination\2= true/' \
      -e 's|^resource "aws_s3_bucket" "media" {$|resource "aws_s3_bucket" "media" {\
  force_destroy = true|' \
      -e 's|^resource "aws_ecr_repository" "app" {$|resource "aws_ecr_repository" "app" {\
  force_delete = true|' \
      "$f")
    printf '%s\n' "$s" > "$f"
  done
}

write_vars() {
  local expires=$1
  cat > "$TF/member.auto.tfvars" <<EOF
# member-env.sh 가 만든다. 고치지 않는다
aws_profile          = ""
allowed_account_ids  = ["$ACCOUNT"]
domain_name          = ""
alert_email          = "${MEMBER_ALERT_EMAIL:-}"
media_bucket_name    = "$PROJECT-media-$ACCOUNT"
app_image_repository = "$APP_IMAGE_REPOSITORY"
load_test_enabled    = true
extra_spring_profiles = "$EXTRA_PROFILES"
monthly_budget_usd   = "50"
member_expires_at    = "$expires"
EOF
}

# 앱과 배치가 켜는 스프링 프로필을 한 줄로 보인다. loadtest 가 있으면 결제는 토스 대신 목이다
run_mode() {
  local app batch
  app=$(terraform -chdir="$TF" output -json spring_profiles 2> /dev/null | sed -n 's/.*"app": *"\([^"]*\)".*/\1/p')
  batch=$(terraform -chdir="$TF" output -json spring_profiles 2> /dev/null | sed -n 's/.*"batch": *"\([^"]*\)".*/\1/p')
  [ -n "$app" ] || { echo 없음; return; }
  case ",$app," in
    *,loadtest,*) echo "앱 $app, 배치 $batch (부하 시험, 결제는 목)" ;;
    *) echo "앱 $app, 배치 $batch" ;;
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

latest_sha() {
  aws ecr describe-images --region "$REGION" --registry-id "$OUR_ACCOUNT" --repository-name "$PROJECT-dev" \
    --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text
}

expires_at() {
  date -u -d "+$HOURS hours" +%Y-%m-%dT%H:%M:%S 2> /dev/null || date -u -v+"$HOURS"H +%Y-%m-%dT%H:%M:%S
}

case "$CMD" in
up)
  log "1. 준비 (계정 $ACCOUNT)"
  check_fresh
  [ -n "$SHA" ] || SHA=$(latest_sha)
  [ -n "$SHA" ] && [ "$SHA" != "None" ] || die "개발 ECR 에서 이미지를 못 찾았다"
  ensure_state_bucket
  ensure_secrets
  EXPIRES=$(expires_at)
  prepare_copy
  write_vars "$EXPIRES"
  tf_init

  # 인스턴스가 뜨면서 이 값을 읽는다. 먼저 만들어 채워 두어야 첫 부팅부터 그 이미지로 뜬다
  log "2. 이미지 $SHA"
  terraform -chdir="$TF" apply -auto-approve -input=false -target=aws_ssm_parameter.current_sha > /dev/null
  aws ssm put-parameter --name "/$PROJECT/current-sha" --type String --overwrite --value "$SHA" > /dev/null

  log "3. terraform apply (처음은 20분쯤 걸린다)"
  terraform -chdir="$TF" apply -auto-approve -input=false

  ALB=$(terraform -chdir="$TF" output -raw alb_dns_name)
  log "4. 앱 대기 http://$ALB"
  ok=""
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 5 "http://$ALB/v3/api-docs" > /dev/null 2>&1; then ok=1; break; fi
    sleep 10
  done
  [ -n "$ok" ] || log "   10분 안에 응답하지 않았다. status 와 앱 로그를 본다"

  LT=$(aws ec2 describe-instances --filters "Name=tag:Role,Values=load-test" "Name=instance-state-name,Values=running" \
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
  [ -d "$TF" ] || die "이 계정에 띄운 적이 없다"
  tf_init
  printf '정리 시각(UTC) %s\n' "$(terraform -chdir="$TF" output -raw member_expires_at 2> /dev/null || echo 없음)"
  printf 'ALB           %s\n' "$(terraform -chdir="$TF" output -raw alb_dns_name 2> /dev/null || echo 없음)"
  printf '이미지        %s\n' "$(aws ssm get-parameter --name "/$PROJECT/current-sha" --query Parameter.Value --output text 2> /dev/null || echo 없음)"
  printf '운영 모드     %s\n' "$(run_mode)"
  printf '\n떠 있는 인스턴스\n'
  aws ec2 describe-instances --filters "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,InstanceType]' --output text | sed 's/^/  /'
  MON=$(aws ec2 describe-instances --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
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
  [ -d "$TF" ] || die "이 계정에 띄운 적이 없다"
  log "1. terraform destroy"
  tf_init
  # 정리 시각은 상관없다. 변수만 채운다
  terraform -chdir="$TF" destroy -auto-approve -input=false
  log "2. 남은 것"
  printf '  EC2 %s, RDS %s, ALB %s, NAT %s, EIP %s\n' \
    "$(aws ec2 describe-instances --filters 'Name=instance-state-name,Values=running,pending,stopping,stopped' --query 'length(Reservations[].Instances[])' --output text)" \
    "$(aws rds describe-db-instances --query 'length(DBInstances)' --output text)" \
    "$(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text)" \
    "$(aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending --query 'length(NatGateways)' --output text)" \
    "$(aws ec2 describe-addresses --query 'length(Addresses)' --output text)"
  log "끝. 시크릿(SSM)과 상태 버킷은 다음 up 을 위해 남긴다. 돈은 들지 않는다"
  ;;
esac

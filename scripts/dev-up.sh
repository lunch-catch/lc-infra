#!/usr/bin/env bash
#
# 개발 서버를 올린다 (docs/system-design/런치캐치_개발서버.md 7장).
# 없으면 만들고, 멈춰 있으면 켠다. 운영(terraform/)과 무관하게 돈다.
#
#   ./dev-up.sh
set -euo pipefail

PROJECT="${PROJECT:-lunchcatch}"
REGION="${AWS_REGION:-ap-northeast-2}"

# 프로필을 빠뜨려도 default 자격증명(다른 계정)으로 가지 않게 한다.
if [ -z "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  export AWS_PROFILE=lunchcatch
fi
ACCOUNT_ID="${ACCOUNT_ID:-762794225116}"
current_account=$(aws sts get-caller-identity --query Account --output text)
if [ "$current_account" != "$ACCOUNT_ID" ]; then
  printf 'ERROR: 계정 %s 를 가리킨다. %s 여야 한다. AWS_PROFILE 을 확인한다\n' "$current_account" "$ACCOUNT_ID" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_HOST="${API_HOST:-api.dev.lunchcatch.com}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 1. 개발 전용 시크릿. 없으면 만든다. 사람이 정할 값이 아니다.
#    서버의 refresh 가 이 값이 없으면 실패해 부팅이 멈춘다. 그래서 서버보다 먼저 만든다.
log "1. 개발 시크릿"
ensure() {
  local name="$1" value="$2"
  if aws ssm get-parameter --name "$name" --region "$REGION" > /dev/null 2>&1; then
    log "   $name 있음"
  else
    aws ssm put-parameter --name "$name" --region "$REGION" --type SecureString --value "$value" > /dev/null
    log "   $name 만듦"
  fi
}
# 운영과 다른 키다. 개발에서 찍은 토큰이 운영에서 통과하면 안 된다
ensure "/$PROJECT/dev/jwt-signing-key" "$(openssl rand -base64 48)"
# MySQL 비밀번호는 41자를 넘지 않게 hex 32자로 만든다
ensure "/$PROJECT/dev/db-password" "$(openssl rand -hex 16)"

# 카카오 넷은 운영과 같은 값을 쓴다. 운영 apply.sh 가 만든다. 비어 있으면 앱이 안 뜬다
for k in kakao-client-id kakao-client-secret kakao-app-id kakao-admin-key; do
  v=$(aws ssm get-parameter --name "/$PROJECT/$k" --region "$REGION" --with-decryption \
    --query 'Parameter.Value' --output text 2>/dev/null || echo missing)
  [ "$v" != "missing" ] && [ "$v" != "unset" ] || die "/$PROJECT/$k 가 비어 있다. 운영과 같은 카카오 값을 먼저 넣어라"
done

# 2. 서버. 이미 있으면 Terraform 은 바꿀 것이 없다
log "2. terraform"
cd "$ROOT/dev"
terraform init -input=false -backend-config=backend.hcl > /dev/null
terraform apply -auto-approve -input=false
instance_id=$(terraform output -raw instance_id)

# 3. 멈춰 있으면 켠다. dev-down.sh 는 지우지 않고 중지한다
state=$(aws ec2 describe-instances --instance-ids "$instance_id" --region "$REGION" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)
if [ "$state" = "stopped" ]; then
  log "3. 켠다 $instance_id"
  aws ec2 start-instances --instance-ids "$instance_id" --region "$REGION" > /dev/null
  aws ec2 wait instance-running --instance-ids "$instance_id" --region "$REGION"
  restarted=1
else
  log "3. $instance_id 가 $state 다"
  restarted=0
fi

# 4. 응답을 기다린다. 처음 만들 때는 Docker 설치, 인증서 발급, 이미지 pull 까지 몇 분 걸린다
sha=$(aws ssm get-parameter --name "/$PROJECT/dev/current-sha" --region "$REGION" \
  --query 'Parameter.Value' --output text 2>/dev/null || true)
if [ -z "$sha" ]; then
  log "4. develop 배포 기록이 없어 앱이 뜨지 않는다"
  log "   lc-backend 에서 deploy-dev 워크플로를 한 번 돌려라. 이미지를 올리고 이 서버에 띄운다"
  exit 0
fi

# 멈춰 있던 서버는 디스크의 옛 .env 로 컨테이너를 다시 띄운다. 그동안 develop 에 병합된 것이 빠진다.
# refresh 가 SSM 을 다시 읽어 current-sha 로 맞춘다. 2026-10-12 에 옛 이미지로 뜬 것을 보고 넣었다.
if [ "$restarted" = 1 ]; then
  log "4. 최신 develop 으로 맞춘다 ($sha)"
  for _ in $(seq 1 30); do
    online=$(aws ssm describe-instance-information --region "$REGION" \
      --filters "Key=InstanceIds,Values=$instance_id" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)
    [ "$online" = "Online" ] && break
    sleep 5
  done
  [ "$online" = "Online" ] || die "SSM 에이전트가 붙지 않았다. 손으로 lunchcatch-dev-refresh 를 돌려라"
  cmd_id=$(aws ssm send-command --instance-ids "$instance_id" --region "$REGION" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"/usr/local/bin/$PROJECT-dev-refresh\"]" \
    --query 'Command.CommandId' --output text)
  aws ssm wait command-executed --command-id "$cmd_id" --instance-id "$instance_id" --region "$REGION" \
    || die "refresh 가 실패했다. aws ssm get-command-invocation --command-id $cmd_id --instance-id $instance_id"
fi

log "4. https://$API_HOST 대기 (상한 600초, 이미지 $sha)"
deadline=$(( $(date +%s) + 600 ))
until curl -fsS --max-time 5 "https://$API_HOST/v3/api-docs" > /dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "   상한 초과. 서버에서 확인하라"
    log "   aws ssm start-session --target $instance_id"
    log "   sudo docker compose -f /opt/$PROJECT-dev/compose.yaml ps"
    exit 1
  fi
  sleep 10
done
log "   응답한다. https://$API_HOST"

# 테스트 관리자를 넣는다. 서버를 새로 만들면 DB 가 비어 있다. 있으면 건너뛴다
"$ROOT/scripts/seed-admin.sh" dev

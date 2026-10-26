#!/usr/bin/env bash
#
# 기본 계정 묶음의 비밀번호를 바꾼다. SSM 의 평문과 해시, DB 의 그 계정 행을 함께 바꾼다.
#
#   ./account-password.sh prod scenario          새 비밀번호를 묻는다
#   ./account-password.sh dev all                네 묶음을 같은 비밀번호로 바꾼다
#   NEW_PASSWORD=... ./account-password.sh prod demo-owner
#
# 묶음은 account-passwords.sh 와 같다. scenario(기본 세계 점주와 관리자), demo-owner, demo-admin, superadmin.
# SSM 만 바꾸면 안 된다. 기본 세계는 이미 있는 계정 행을 건너뛰어서 DB 의 해시가 예전 값으로 남는다.
# DB 는 예전 해시를 가진 행만 바꾼다. 실제로 가입한 점주나 따로 비밀번호를 바꾼 계정은 해시가 달라 건드리지 않는다.
# 로그인 중인 세션은 끊지 않는다. 시연이나 촬영 중에 바꿔도 화면이 튕기지 않게 하려는 것이다.
# DB 를 먼저 바꾸고 SSM 을 나중에 바꾼다. DB 가 실패하면 SSM 은 예전 값 그대로라 둘이 어긋나지 않는다.
set -euo pipefail

PROJECT="${PROJECT:-lunchcatch}"
REGION="${AWS_REGION:-ap-northeast-2}"
TARGET="${1:-}"
GROUP="${2:-}"

if [ -z "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  export AWS_PROFILE=lunchcatch
fi
ACCOUNT_ID="${ACCOUNT_ID:-762794225116}"
current_account=$(aws sts get-caller-identity --query Account --output text)
if [ "$current_account" != "$ACCOUNT_ID" ]; then
  printf 'ERROR: 계정 %s 를 가리킨다. %s 여야 한다. AWS_PROFILE 을 확인한다\n' "$current_account" "$ACCOUNT_ID" >&2
  exit 1
fi

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "오류: $*"; exit 1; }

case "$TARGET" in
  prod)
    tag="batch"; ssm_prefix="/$PROJECT"
    sql_cmd='set -a; . /opt/'"$PROJECT"'/.env; set +a; docker run --rm -i -e MYSQL_PWD="$DB_PASSWORD" mysql:8.4 mysql --default-character-set=utf8mb4 -N -h "$DB_ENDPOINT" -u '"$PROJECT"' '"$PROJECT"''
    ;;
  dev)
    tag="dev-server"; ssm_prefix="/$PROJECT/dev"
    sql_cmd='docker exec -i '"$PROJECT"'-dev-mysql-1 sh -c '"'"'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --default-character-set=utf8mb4 -N -u root '"$PROJECT"''"'"''
    ;;
  *) sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

case "$GROUP" in
  scenario|demo-owner|demo-admin|superadmin) groups="$GROUP" ;;
  all) groups="scenario demo-owner demo-admin superadmin" ;;
  *) die "묶음은 scenario, demo-owner, demo-admin, superadmin, all 중 하나다" ;;
esac

command -v htpasswd > /dev/null || die "htpasswd 가 없다. 해시를 만들 수 없다 (macOS 는 기본으로 있다)"

password="${NEW_PASSWORD:-}"
if [ -z "$password" ]; then
  read -r -s -p "새 비밀번호: " password; echo
  read -r -s -p "한 번 더: " again; echo
  [ "$password" = "$again" ] || die "두 번 입력한 값이 다르다"
fi
# 점주 로그인은 10 ~ 20자만 받는다(OwnerLoginRequest). 짧으면 점주는 영영 로그인하지 못한다
len=${#password}
[ "$len" -ge 10 ] && [ "$len" -le 20 ] || die "비밀번호는 10 ~ 20자여야 한다 (지금 ${len}자)"

instance_id=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Role,Values=$tag" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$instance_id" != "None" ] && [ -n "$instance_id" ] || die "$TARGET 서버가 떠 있지 않다"

# 서버에 명령 문자열로 해시를 넘기면 $ 가 셸에서 풀린다. base64 로 감싸 넘기고 서버에서 푼다
run_sql() {
  local sql_b64 remote params cmd_id status out
  sql_b64=$(printf '%s' "$1" | base64 | tr -d '\n')
  remote="set -eu; echo $sql_b64 | base64 -d > /tmp/account-password.sql; $sql_cmd < /tmp/account-password.sql; rm -f /tmp/account-password.sql"
  params=$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]]}))' "$remote")
  cmd_id=$(aws ssm send-command --region "$REGION" --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript --parameters "$params" --query 'Command.CommandId' --output text) \
    || die "명령을 보내지 못했다"
  status=Pending
  for _ in $(seq 1 60); do
    sleep 3
    status=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
      --instance-id "$instance_id" --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in Success|Failed|Cancelled|TimedOut) break ;; esac
  done
  out=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
    --instance-id "$instance_id" --query '[StandardOutputContent,StandardErrorContent]' --output text 2>/dev/null || true)
  [ "$status" = "Success" ] || die "$TARGET DB 를 고치지 못했다 ($status). $(echo "$out" | grep -v -i 'password on the command line' | tail -2)"
  echo "$out" | grep -o 'rows=[0-9]*,[0-9]*' | tail -1
}

for g in $groups; do
  name="$ssm_prefix/account-$g-password"
  old_hash=$(aws ssm get-parameter --region "$REGION" --name "$name-hash" --query Parameter.Value --output text) \
    || die "$name-hash 가 없다. account-passwords.sh 로 먼저 만든다"
  # htpasswd 는 $2y$ 로 낸다. 알고리즘은 같고 앱의 기본값과 맞추려 $2a$ 로 바꾼다
  new_hash=$(htpasswd -nbBC 10 "" "$password" | tr -d ':\n' | sed 's/^\$2y\$/$2a$/')
  rows=$(run_sql "SET time_zone = '+09:00';
UPDATE admin SET password_hash = '$new_hash', updated_at = NOW(6) WHERE password_hash = '$old_hash';
SET @a = ROW_COUNT();
UPDATE owner SET password_hash = '$new_hash', updated_at = NOW(6) WHERE password_hash = '$old_hash';
SELECT CONCAT('rows=', @a, ',', ROW_COUNT());")
  aws ssm put-parameter --name "$name-hash" --region "$REGION" --type String --overwrite \
    --value "$new_hash" --description "$g 비밀번호의 BCrypt 해시. 기본 세계가 넣는다" > /dev/null
  aws ssm put-parameter --name "$name" --region "$REGION" --type SecureString --overwrite \
    --value "$password" --description "$g 로그인 비밀번호" > /dev/null
  counts=${rows#rows=}
  log "$g ($TARGET): DB 관리자 ${counts%,*}행, 점주 ${counts#*,}행과 SSM 을 바꿨다"
done
log "다음 배포 때 서버가 새 해시를 받는다. 해시가 바뀐 시연 층(R__demo)은 그 배포에서 다시 돈다"

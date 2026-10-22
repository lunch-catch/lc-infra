#!/usr/bin/env bash
#
# superadmin 의 비밀번호를 SSM 의 기본 계정 비밀번호로 맞춘다 (lc-infra #29).
# 기본 세계(lc-backend db/base)는 이미 있는 superadmin 을 건너뛴다. 예전 seed-admin.sh 가 넣은 superadmin 은
# 테스트 관리자 비밀번호를 그대로 갖고 있어 이 스크립트로 한 번 맞춘다. 비밀번호를 바꿀 때도 쓴다.
#
#   ./superadmin-password.sh prod   운영. 배치 서버 하나에서 RDS 의 superadmin 을 고친다
#   ./superadmin-password.sh dev    개발. 개발 서버의 MySQL 컨테이너에서 고친다
#
# 해시는 SSM <접두사>/account-superadmin-password-hash 에 있다(scripts/account-passwords.sh 가 만든다).
# 서버가 자기 역할로 직접 읽는다. 해시의 $ 가 명령 문자열을 거치지 않게 하려는 것이다.
# 토큰 발급 세대를 올려 이전 비밀번호로 받은 토큰을 모두 끊는다.
set -euo pipefail

PROJECT="${PROJECT:-lunchcatch}"
REGION="${AWS_REGION:-ap-northeast-2}"
TARGET="${1:-}"

if [ -z "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  export AWS_PROFILE=lunchcatch
fi

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "오류: $*"; exit 1; }

case "$TARGET" in
  prod)
    tag="batch"
    # 배치 서버의 .env 에 DB 주소와 비밀번호가 있다. 호스트에는 mysql 클라이언트가 없어 이미지로 돌린다.
    sql_cmd='set -a; . /opt/'"$PROJECT"'/.env; set +a; docker run --rm -i -e MYSQL_PWD="$DB_PASSWORD" mysql:8.4 mysql --default-character-set=utf8mb4 -h "$DB_ENDPOINT" -u '"$PROJECT"' '"$PROJECT"''
    ;;
  dev)
    tag="dev-server"
    sql_cmd='docker exec -i '"$PROJECT"'-dev-mysql-1 sh -c '"'"'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --default-character-set=utf8mb4 -u root '"$PROJECT"''"'"''
    ;;
  *)
    printf 'usage: %s prod|dev\n' "$0" >&2
    exit 1 ;;
esac

instance_id=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=$tag" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$instance_id" != "None" ] && [ -n "$instance_id" ] || die "$TARGET 서버가 떠 있지 않다"

# 서버 쪽에서 돈다. 값은 SSM 에서 직접 읽는다.
# SSM Run Command 는 sh(dash) 로 돈다. pipefail 이 없다.
case "$TARGET" in
  prod) ssm_prefix="/$PROJECT" ;;
  dev) ssm_prefix="/$PROJECT/dev" ;;
esac
remote=$(cat <<EOF
set -eu
H=\$(aws ssm get-parameter --region $REGION --name "$ssm_prefix/account-superadmin-password-hash" --query Parameter.Value --output text)
$sql_cmd <<SQL
SET time_zone = '+09:00';
UPDATE admin
   SET password_hash = '\$H',
       refresh_token_issuance_version = refresh_token_issuance_version + 1,
       updated_at = NOW(6)
 WHERE login_id = 'superadmin';
SELECT CONCAT('rows=', ROW_COUNT());
SQL
EOF
)

params=$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]]}))' "$remote")
cmd_id=$(aws ssm send-command --region "$REGION" --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript --parameters "$params" \
  --query 'Command.CommandId' --output text) || die "명령을 보내지 못했다"

status=Pending
for _ in $(seq 1 40); do
  sleep 3
  status=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
    --instance-id "$instance_id" --query Status --output text 2>/dev/null || echo Pending)
  case "$status" in Success|Failed|Cancelled|TimedOut) break ;; esac
done

out=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
  --instance-id "$instance_id" --query '[StandardOutputContent,StandardErrorContent]' --output text 2>/dev/null || true)
[ "$status" = "Success" ] || die "$TARGET 에서 고치지 못했다 ($status). $(echo "$out" | grep -v -i 'password on the command line' | tail -2)"

case "$out" in
  *rows=1*) log "superadmin 비밀번호를 SSM 값으로 맞췄다 ($TARGET)" ;;
  *rows=0*) die "superadmin 이 없다 ($TARGET). 기본 세계가 켜져 있으면 앱이 기동할 때 넣는다" ;;
  *) die "결과를 읽지 못했다 ($TARGET): $out" ;;
esac

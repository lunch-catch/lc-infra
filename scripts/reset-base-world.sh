#!/usr/bin/env bash
#
# 기본 세계를 다시 넣기 전의 정리를 돌린다 (lc-backend #858).
# lc-backend 의 scripts/reset_base_world.sql 을 서버의 DB 에 돌리고, 날짜와 캠페인에 묶인 Valkey 키를 지운다.
# 계정(admin, owner, member)은 남는다. 그 뒤 새 코드로 앱을 띄우면 기본 세계와 시연 층이 그날 기준으로 다시 들어간다.
#
#   ./reset-base-world.sh dev  <lc-backend 경로>/scripts/reset_base_world.sql
#   ./reset-base-world.sh prod <lc-backend 경로>/scripts/reset_base_world.sql
#
# 순서: 정리 -> 새 코드 배포. 정리 전에 새 코드로 뜨면 체크섬이 어긋나 앱이 뜨지 않는다(개발은 돌던 앱이 남는다).
# Valkey 는 쿠폰 큐, 소진 해시, 서빙과 노출 기록 키만 지운다. 로그인 토큰은 남는다.
# 되돌릴 수 없다. 운영은 묻고 진행한다.
set -euo pipefail

PROJECT="${PROJECT:-lunchcatch}"
REGION="${AWS_REGION:-ap-northeast-2}"
TARGET="${1:-}"
SQL="${2:-}"

if [ -z "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  export AWS_PROFILE=lunchcatch
fi

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "오류: $*"; exit 1; }

[ -f "$SQL" ] || die "정리 SQL 을 찾지 못했다: $SQL"

# 지울 Valkey 키 묶음이다. 앱이 그날 DB 로 다시 만든다(쿠폰 큐는 첫 발급 요청, 소진 해시는 첫 차감 때)
PATTERNS="coupon* billing:* adserving:* impression:* swipe:*"

case "$TARGET" in
  prod)
    tag="batch"
    sql_cmd='set -a; . /opt/'"$PROJECT"'/.env; set +a; docker run --rm -i -e MYSQL_PWD="$DB_PASSWORD" mysql:8.4 mysql --default-character-set=utf8mb4 -h "$DB_ENDPOINT" -u '"$PROJECT"' '"$PROJECT"''
    cache_cmd='set -a; . /opt/'"$PROJECT"'/.env; set +a; docker run --rm valkey/valkey:9.0-alpine sh -c "for p in '"$PATTERNS"'; do valkey-cli -h $CACHE_ENDPOINT --scan --pattern \"\$p\" | xargs -r -n 500 valkey-cli -h $CACHE_ENDPOINT UNLINK > /dev/null; done"'
    printf '운영 DB 의 기본 세계와 시연 데이터를 지운다. 계정은 남는다. 진행하려면 prod 를 입력한다: '
    read -r answer
    [ "$answer" = "prod" ] || die "멈췄다"
    ;;
  dev)
    tag="dev-server"
    sql_cmd='docker exec -i '"$PROJECT"'-dev-mysql-1 sh -c '"'"'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --default-character-set=utf8mb4 -u root '"$PROJECT"''"'"''
    cache_cmd='docker exec '"$PROJECT"'-dev-valkey-1 sh -c "for p in '"$PATTERNS"'; do valkey-cli --scan --pattern \"\$p\" | xargs -r -n 500 valkey-cli UNLINK > /dev/null; done"'
    ;;
  *)
    printf 'usage: %s prod|dev <reset_base_world.sql>\n' "$0" >&2
    exit 1 ;;
esac

instance_id=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=$tag" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$instance_id" != "None" ] && [ -n "$instance_id" ] || die "$TARGET 서버가 떠 있지 않다"

# SQL 은 base64 로 실어 서버에서 풀어 돌린다. SSM Run Command 는 sh(dash) 로 돈다
sql64=$(base64 < "$SQL" | tr -d '\n')
remote=$(cat <<EOF
set -eu
echo $sql64 | base64 -d > /tmp/reset_base_world.sql
$sql_cmd < /tmp/reset_base_world.sql
rm -f /tmp/reset_base_world.sql
$cache_cmd
echo cache=cleared
EOF
)

params=$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": ["900"]}))' "$remote")
cmd_id=$(aws ssm send-command --region "$REGION" --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript --parameters "$params" \
  --query 'Command.CommandId' --output text) || die "명령을 보내지 못했다"

log "$TARGET 정리 중 ($instance_id)"
status=Pending
for _ in $(seq 1 180); do
  sleep 5
  status=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
    --instance-id "$instance_id" --query Status --output text 2>/dev/null || echo Pending)
  case "$status" in Success|Failed|Cancelled|TimedOut) break ;; esac
done

out=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
  --instance-id "$instance_id" --query '[StandardOutputContent,StandardErrorContent]' --output text 2>/dev/null || true)
[ "$status" = "Success" ] || die "$TARGET 정리가 실패했다 ($status). $(echo "$out" | grep -v -i 'password on the command line' | tail -5)"
echo "$out" | grep -E 'reset done|cache=' || true
log "정리했다 ($TARGET). 이제 새 코드로 배포한다"

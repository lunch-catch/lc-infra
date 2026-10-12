#!/usr/bin/env bash
#
# 테스트용 최고 관리자 한 명을 DB 에 넣는다 (docs/deploy/README.md "테스트 관리자").
# 관리자는 최고 관리자가 API 로 발급하므로 첫 한 명만 밖에서 넣는다.
# 이미 그 아이디가 있으면 아무것도 하지 않는다. 몇 번 돌려도 안전하다.
#
#   ./seed-admin.sh prod    운영. 배치 서버 하나에서 RDS 에 붙어 넣는다. deploy.sh 끝에서 돈다
#   ./seed-admin.sh dev     개발. 개발 서버의 MySQL 컨테이너에 넣는다. dev-up.sh 끝에서 돈다
#
# 값은 SSM /<project>/test-admin-* 에 있다. 테스트 계정이라 String 으로 둔다.
# 서버가 자기 역할로 직접 읽는다. 해시의 $ 가 명령 문자열을 거치지 않게 하려는 것이다.
#
# 실패해도 배포를 실패로 만들지 않는다. 앱은 관리자 없이도 돈다. 경고만 남긴다.
set -euo pipefail

PROJECT="${PROJECT:-lunchcatch}"
REGION="${AWS_REGION:-ap-northeast-2}"
TARGET="${1:-}"

if [ -z "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  export AWS_PROFILE=lunchcatch
fi

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "seed-admin 경고: $*"; exit 0; }

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
[ "$instance_id" != "None" ] && [ -n "$instance_id" ] || warn "$TARGET 서버가 떠 있지 않다. 건너뛴다"

# 서버 쪽에서 돈다. 값은 SSM 에서 직접 읽는다.
# 시각은 Asia/Seoul 로 넣는다. 앱이 세션 시간대를 Asia/Seoul 로 두고 쓰므로 같은 기준이어야 한다.
# 문자셋을 utf8mb4 로 고정한다. 빼면 클라이언트가 latin1 로 보내 이름(최고관리자)이 깨져 저장된다.
# admin 테이블은 앱이 기동하며 Flyway 로 만든다. 없으면 앱이 아직 안 뜬 것이라 실패로 끝난다.
# SSM Run Command 는 sh(dash) 로 돈다. pipefail 이 없다.
remote=$(cat <<EOF
set -eu
p() { aws ssm get-parameter --region $REGION --name "/$PROJECT/test-admin-\$1" --query Parameter.Value --output text; }
L=\$(p login-id); H=\$(p password-hash); N=\$(p name)
$sql_cmd <<SQL
SET time_zone = '+09:00';
INSERT INTO admin (login_id, password_hash, name, role, status, created_at, updated_at)
SELECT '\$L', '\$H', '\$N', 'SUPER_ADMIN', 'ACTIVE', NOW(6), NOW(6) FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM admin WHERE login_id = '\$L');
SELECT CONCAT('rows=', ROW_COUNT());
SQL
EOF
)

params=$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]]}))' "$remote")
cmd_id=$(aws ssm send-command --region "$REGION" --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript --parameters "$params" \
  --query 'Command.CommandId' --output text) || warn "명령을 보내지 못했다"

status=Pending
for _ in $(seq 1 40); do
  sleep 3
  status=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
    --instance-id "$instance_id" --query Status --output text 2>/dev/null || echo Pending)
  case "$status" in Success|Failed|Cancelled|TimedOut) break ;; esac
done

out=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
  --instance-id "$instance_id" --query '[StandardOutputContent,StandardErrorContent]' --output text 2>/dev/null || true)
[ "$status" = "Success" ] || warn "$TARGET 에 넣지 못했다 ($status). $(echo "$out" | grep -v -i 'password on the command line' | tail -2)"

case "$out" in
  *rows=1*) log "테스트 관리자를 넣었다 ($TARGET)" ;;
  *rows=0*) log "테스트 관리자가 이미 있다 ($TARGET)" ;;
  *) log "테스트 관리자 결과를 읽지 못했다 ($TARGET): $out" ;;
esac

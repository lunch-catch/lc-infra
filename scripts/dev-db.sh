#!/usr/bin/env bash
#
# 개발 서버 MySQL 에 내 컴퓨터의 포트로 붙는다 (docs/system-design/런치캐치_개발서버.md 10장).
# SSM 포트 포워딩이라 서버에 열린 포트가 없다. 이 창을 닫으면 연결이 끊긴다.
#
#   ./dev-db.sh            localhost:13306 으로 연다
#   LOCAL_PORT=3307 ./dev-db.sh
#
# 필요한 것: AWS CLI, session-manager-plugin (brew install --cask session-manager-plugin)
# 팀원 키는 lunchcatch-dev 프로필에 둔다. 다른 프로필이면 AWS_PROFILE 로 넘긴다.
set -euo pipefail

if [ -z "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  export AWS_PROFILE=lunchcatch-dev
fi
REGION="${AWS_REGION:-ap-northeast-2}"
LOCAL_PORT="${LOCAL_PORT:-13306}"

command -v session-manager-plugin > /dev/null \
  || { echo "session-manager-plugin 이 없다. brew install --cask session-manager-plugin" >&2; exit 1; }

instance_id=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=dev-server" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$instance_id" != "None" ] && [ -n "$instance_id" ] \
  || { echo "개발 서버가 꺼져 있다. 인프라 담당에게 켜 달라고 한다" >&2; exit 1; }

password=$(aws ssm get-parameter --region "$REGION" --name /lunchcatch/dev/team-db-password \
  --with-decryption --query Parameter.Value --output text)

cat <<INFO
개발 DB 에 연결한다. 이 창을 열어 둔 동안만 붙는다 (Ctrl+C 로 끊는다).

  Host      127.0.0.1
  Port      $LOCAL_PORT
  Database  lunchcatch
  User      team
  Password  $password

  mysql -h 127.0.0.1 -P $LOCAL_PORT -u team -p lunchcatch

데이터는 읽고 쓸 수 있고 테이블 구조는 바꿀 수 없다. 팀원 모두가 쓰는 데이터라 지울 때 조심한다.
INFO

exec aws ssm start-session --region "$REGION" --target "$instance_id" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "portNumber=3306,localPortNumber=$LOCAL_PORT"

#!/usr/bin/env bash
#
# 개발 서버를 내린다. 지우지 않고 중지한다 (docs/system-design/런치캐치_개발서버.md 7장).
#
# 지우면 Caddy 가 인증서를 다시 받는데 Let's Encrypt 는 같은 이름에 주 5회까지만 발급한다.
# 중지하면 인증서와 MySQL 데이터가 디스크에 남고, 남는 비용은 디스크와 고정 IP 뿐이다.
#
# 아예 지우려면
#   cd dev && terraform destroy
set -euo pipefail

PROJECT="${PROJECT:-lunchcatch}"
REGION="${AWS_REGION:-ap-northeast-2}"

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

# 상태 파일이 아니라 태그로 찾는다. 이 스크립트는 Terraform 을 돌리지 않는다
ids=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=dev-server" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

if [ -z "$ids" ]; then
  log "떠 있는 개발 서버가 없다"
  exit 0
fi

log "중지 $ids"
# shellcheck disable=SC2086
aws ec2 stop-instances --instance-ids $ids --region "$REGION" > /dev/null
# shellcheck disable=SC2086
aws ec2 wait instance-stopped --instance-ids $ids --region "$REGION"
log "멈췄다. 다시 켜려면 ./scripts/dev-up.sh"

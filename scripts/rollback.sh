#!/usr/bin/env bash
#
# 롤백은 이전 SHA 로 배포를 다시 하는 것이다. 별도 경로를 두지 않는다.
#
# 구 인스턴스가 아직 살아 있으면 신규만 지우면 되지만(1~2분),
# 이미 종료했으면 이전 SHA 로 증설부터 다시 해야 한다(6~8분).
#
# SSM 값도 함께 되돌아간다. deploy.sh 가 2번 단계에서 갱신하기 때문이다.
# 되돌리지 않으면 다음 ASG 교체에서 롤백한 버전이 아니라 문제 버전이 올라온다.
#
#   ./rollback.sh <되돌아갈 커밋 SHA>

set -euo pipefail

PROJECT="${PROJECT:-lunchcatch}"
REGION="${AWS_REGION:-ap-northeast-2}"

# 프로필을 빠뜨려도 default 자격증명(다른 계정)으로 가지 않게 한다.
# CI 는 OIDC 자격증명을 환경변수로 받으므로 프로필을 건드리지 않는다. 없는 프로필을 걸면 CLI 가 죽는다.
if [ -z "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  export AWS_PROFILE=lunchcatch
fi
# 그래도 다른 계정을 가리키면 아무것도 하기 전에 멈춘다. terraform/versions.tf 의 allowed_account_ids 와 같은 장치다.
ACCOUNT_ID="${ACCOUNT_ID:-762794225116}"
current_account=$(aws sts get-caller-identity --query Account --output text)
if [ "$current_account" != "$ACCOUNT_ID" ]; then
  printf 'ERROR: 계정 %s 를 가리킨다. %s 여야 한다. AWS_PROFILE 을 확인한다\n' "$current_account" "$ACCOUNT_ID" >&2
  exit 1
fi

SHA="${1:?되돌아갈 커밋 SHA 를 넘겨라}"

current=$(aws ssm get-parameter --name "/$PROJECT/current-sha" --region "$REGION" \
  --query 'Parameter.Value' --output text)

echo "롤백 $current -> $SHA"
exec "$(dirname "$0")/deploy.sh" "$SHA"

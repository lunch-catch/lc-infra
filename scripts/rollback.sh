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
SHA="${1:?되돌아갈 커밋 SHA 를 넘겨라}"

current=$(aws ssm get-parameter --name "/$PROJECT/current-sha" --region "$REGION" \
  --query 'Parameter.Value' --output text)

echo "롤백 $current -> $SHA"
exec "$(dirname "$0")/deploy.sh" "$SHA"

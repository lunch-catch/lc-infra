#!/usr/bin/env bash
#
# 개발 서버 앱 로그를 본다 (docs/system-design/런치캐치_개발서버.md 10장).
# CloudWatch Logs /lunchcatch/dev/app 를 읽는다. 배포로 컨테이너가 바뀌어도 14일 남는다.
#
#   ./dev-logs.sh                    최근 10분부터 실시간으로 따라간다
#   ./dev-logs.sh 2h                 최근 2시간부터
#   ./dev-logs.sh 30m ERROR          최근 30분 중 ERROR 가 들어간 줄만 (따라가지 않는다)
#   ./dev-logs.sh 1h MEMBER_WITHDRAWAL
#
# 팀원 키는 lunchcatch-dev 프로필에 둔다. 다른 프로필이면 AWS_PROFILE 로 넘긴다.
set -euo pipefail

if [ -z "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  export AWS_PROFILE=lunchcatch-dev
fi
REGION="${AWS_REGION:-ap-northeast-2}"
GROUP=/lunchcatch/dev/app
SINCE="${1:-10m}"
PATTERN="${2:-}"

# 한 줄 JSON 을 "시각 레벨 메시지" 로 보여 준다. jq 가 없으면 원문 그대로 둔다
pretty() {
  if command -v jq > /dev/null; then
    jq -R -r 'fromjson? // . | if type == "object"
      then "\(."@timestamp"[11:23]) \(.level | .[0:5]) \(.message)\(if .stack_trace then "\n" + .stack_trace else "" end)"
      else . end'
  else
    cat
  fi
}

if [ -n "$PATTERN" ]; then
  aws logs tail "$GROUP" --region "$REGION" --since "$SINCE" --format short --filter-pattern "\"$PATTERN\"" \
    | sed -E 's/^[^ ]+ //' | pretty
else
  aws logs tail "$GROUP" --region "$REGION" --since "$SINCE" --format short --follow \
    | sed -E 's/^[^ ]+ //' | pretty
fi

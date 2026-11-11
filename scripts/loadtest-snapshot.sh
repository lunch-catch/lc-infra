#!/usr/bin/env bash
#
# 회차 구간의 그라파나 대시보드를 PNG 로 내려받는다.
#
#   ./loadtest-snapshot.sh --label f4-1           지금부터 거꾸로 5분
#   ./loadtest-snapshot.sh --label F-2 --minutes 10
#   ./loadtest-snapshot.sh --from 1790699360000 --to 1790699480000
#   ./loadtest-snapshot.sh --dash lc-loadtest     한 장만
#   AWS_PROFILE=me ./loadtest-snapshot.sh --lt --label r1   팀원 부하 시험 환경(member-env.sh)에서
#   ./loadtest-snapshot.sh --local --label l1              로컬 구성(observability/local)에서
#   ./loadtest-snapshot.sh --lt --diag v3-run1-profile --from <ms> --to <ms> --trace <ID> --out <결과 문서 폴더>
#                                                  진단 회차의 Call Tree, 트레이스 화면, 06 처리 시간 목표 초과를 찍는다
#
#   --lt               부하 시험 환경이다. 접두사가 lunchcatch-lt 이고 운영 계정 가드 대신 AWS_PROFILE 을 요구한다
#   --local            로컬 구성이다. 터널 없이 localhost 의 그라파나(GRAFANA_PORT, 기본 13000)를 admin 으로 찍는다
#   --label <이름>     저장 폴더에 붙인다
#   --minutes <분>     지금부터 거꾸로 몇 분 (기본 5)
#   --from / --to      유닉스 밀리초로 구간을 직접 준다
#   --dash <uid>       그 대시보드만. 여러 번 줄 수 있다
#   --out <경로>       저장 위치 (기본 loadtest-runs/)
#   --diag <회차>      진단 회차(트레이싱이나 프로파일링을 켠 회차)를 찍는다. 회차 이름은 프로파일의 run 라벨이다.
#                      06 처리 시간 목표 초과를 렌더러로, Call Tree(wall, cpu)와 트레이스 화면을 브라우저 자동화(scripts/diag-capture)로 찍는다.
#                      그림은 --out 폴더에 바로 diag-{회차}-*.png 로 둔다. 결과 문서 옆에 두려는 것이다(lc-infra #106)
#                      회차 구간의 Redis 명령별 호출 수, 서버 평균, 서버 p99 와 느린 명령 건수를 diag-{회차}-redis.txt 로 남긴다(lc-infra #116)
#   --trace <ID>       --diag 와 함께 찍을 트레이스 ID. 여러 번 줄 수 있다. 결과 문서의 진단 표에 적은 가장 느린 트레이스다
#   --baseline <회차> --baseline-from <ms> --baseline-to <ms>
#                      --diag 와 함께 준다. 고치기 전 진단 회차를 기준으로 이 회차를 견준 Diff flame graph(wall, cpu)를
#                      diag-{회차}-diff-{wall|cpu}.png 로 찍는다. 두 회차의 조건(부하, 데이터 규모, 구간 길이)이 같아야 견줄 수 있다(lc-infra #115).
#                      --expand 도 주면 나눈 보기 대신 Diff 의 Call Tree 를 전체 폭으로 그 함수부터 몫이 많이 변한 갈래만 펼쳐 찍는다.
#                      같은 코드로 잰 두 회차도 표본이 적으면 wall 의 몫이 10%p 넘게 흔들린다. Diff 하나로 판정하지 않고 측정 회차의 수치와 함께 본다
#   --fixed <함수>     --baseline, --expand 와 함께 준다. 그 버전에서 고친 함수다. 여러 번 줄 수 있다. Diff 의 Call Tree 에서 몫이 거의
#                      변하지 않았어도 그 함수까지 가는 경로를 남겨, 고쳤는데 몫이 그대로인 것도 보이게 한다
#   --expand <함수>    --diag 의 Call Tree 에서 펼칠 함수. 여러 번 줄 수 있다. 기준을 넘은 API 의 컨트롤러 메서드와 작업 메서드다.
#                      그 줄에서 큰 갈래를 펼치고 Self 가 큰 줄에서 멈춘다. 기준은 scripts/diag-capture/capture.py 가 갖는다.
#                      주지 않으면 맨 위 줄만 보인다
#
# 왜 이 스크립트가 필요한가.
#
# 2026-09-30 장애 회차에서 팀은 수치를 다 남기고 대시보드를 한 장도 안 남겼다. 인프라를 내린
# 뒤에는 되살릴 수 없다. Prometheus 는 모니터링 인스턴스의 도커 볼륨에 담기고 밖으로 내보내는
# 설정이 없으므로, destroy 가 지우면 그 회차의 그림은 영영 없다.
#
# 그래서 회차가 끝난 직후에 부른다. destroy 보다 먼저다.
#
# 렌더러가 필요하다.
#
# observability/compose.yaml 의 renderer 가 떠 있어야 한다. 없으면 그라파나가 PNG 대신
# 오류를 200 으로 돌려주므로 아래에서 PNG 인지 확인한다.
#
# 왜 SSM 터널인가.
#
# 그라파나는 127.0.0.1:3000 에만 묶여 있다. 밖에서 오는 것은 Caddy 가 받고, 3000 인바운드는
# SG-alb 출처만 허용한다. 내 IP 를 SG 에 넣지 않으려면 SSM 이 유일한 길이다.
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-2}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="${OUT_ROOT:-$ROOT/loadtest-runs}"
LOCAL_PORT="${LOCAL_PORT:-13000}"
WIDTH="${WIDTH:-1600}"
# 비워 두면 대시보드마다 패널 배치에서 높이를 잰다. 주면 모든 장을 그 높이로 자른다
HEIGHT="${HEIGHT:-}"

LABEL=""; MINUTES=5; FROM=""; TO=""; DASH=(); LT=""; LOCAL=""; DIAG=""; TRACES=(); EXPANDS=(); BASELINE=""; BASE_FROM=""; BASE_TO=""; FIXED=()

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 인자를 먼저 읽는다. --lt 에 따라 접두사와 계정 가드가 달라진다
while [ $# -gt 0 ]; do
  case "$1" in
    --lt)      LT=1; shift ;;
    --local)   LOCAL=1; shift ;;
    --label)   LABEL="${2:-}"; shift 2 ;;
    --minutes) MINUTES="${2:-}"; shift 2 ;;
    --from)    FROM="${2:-}"; shift 2 ;;
    --to)      TO="${2:-}"; shift 2 ;;
    --dash)    DASH+=("${2:-}"); shift 2 ;;
    --out)     OUT_ROOT="${2:-}"; shift 2 ;;
    --diag)    DIAG="${2:-}"; shift 2 ;;
    --trace)   TRACES+=("${2:-}"); shift 2 ;;
    --expand)  EXPANDS+=("${2:-}"); shift 2 ;;
    --baseline) BASELINE="${2:-}"; shift 2 ;;
    --baseline-from) BASE_FROM="${2:-}"; shift 2 ;;
    --baseline-to) BASE_TO="${2:-}"; shift 2 ;;
    --fixed)   FIXED+=("${2:-}"); shift 2 ;;
    *) die "모르는 인자: $1" ;;
  esac
done

if [ -n "$LOCAL" ]; then
  # 로컬 구성은 AWS 를 부르지 않는다
  LOCAL_PORT="${GRAFANA_PORT:-13000}"
elif [ -n "$LT" ]; then
  #
  # 팀원 부하 시험 환경이다 (member-env.sh, lc-infra #52). 그 사람의 계정이라 계정 ID 를 미리 알 수 없다.
  # 대신 프로필을 반드시 받는다. 빠뜨렸을 때 기본 자격증명의 엉뚱한 계정으로 가지 않게 하려는 것이다.
  #
  PROJECT="${PROJECT:-lunchcatch-lt}"
  [ -n "${AWS_PROFILE:-}${AWS_ACCESS_KEY_ID:-}" ] || die "--lt 에는 AWS_PROFILE 을 준다. member-env.sh up 을 돌린 계정의 프로필이다"
else
  PROJECT="${PROJECT:-lunchcatch}"
  # 프로필을 빠뜨려도 default 자격증명(다른 계정)으로 가지 않게 한다.
  # CI 는 OIDC 자격증명을 환경변수로 받으므로 프로필을 건드리지 않는다. 없는 프로필을 걸면 CLI 가 죽는다.
  if [ -z "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
    export AWS_PROFILE=lunchcatch
  fi
  # 그래도 다른 계정을 가리키면 아무것도 하기 전에 멈춘다. envs/prod/versions.tf 의 allowed_account_ids 와 같은 장치다.
  ACCOUNT_ID="${ACCOUNT_ID:-762794225116}"
  current_account=$(aws sts get-caller-identity --query Account --output text)
  if [ "$current_account" != "$ACCOUNT_ID" ]; then
    printf 'ERROR: 계정 %s 를 가리킨다. %s 여야 한다. AWS_PROFILE 을 확인한다. 부하 시험 환경이면 --lt 를 준다\n' "$current_account" "$ACCOUNT_ID" >&2
    exit 1
  fi
fi

# 구간을 정한다. from 과 to 를 함께 주지 않았으면 지금부터 거꾸로 센다.
if [ -z "$FROM" ] || [ -z "$TO" ]; then
  case "$MINUTES" in ''|*[!0-9]*) die "--minutes 는 숫자다: $MINUTES" ;; esac
  TO=$(( $(date +%s) * 1000 ))
  FROM=$(( TO - MINUTES * 60 * 1000 ))
fi

[ $(( ${#TRACES[@]} + ${#EXPANDS[@]} )) -eq 0 ] || [ -n "$DIAG" ] || die "--trace 와 --expand 는 --diag 와 함께 준다"
[ -z "$BASELINE" ] || { [ -n "$DIAG" ] && [ -n "$BASE_FROM" ] && [ -n "$BASE_TO" ]; } || die "--baseline 은 --diag, --baseline-from, --baseline-to 와 함께 준다"
[ ${#FIXED[@]} -eq 0 ] || { [ -n "$BASELINE" ] && [ ${#EXPANDS[@]} -gt 0 ]; } || die "--fixed 는 --baseline 과 --expand 와 함께 준다"

# 진단 회차는 06 처리 시간 목표 초과만 찍는다. 측정 회차는 트레이싱을 꺼 그 대시보드의 트레이싱 표가 비어 찍지 않는다(lc-infra #94).
# 기본은 여섯 장 전부다. 회차마다 무엇이 문제였는지 미리 알 수 없다.
if [ -n "$DIAG" ]; then
  DASH=(lc-overrun)
elif [ ${#DASH[@]} -eq 0 ]; then
  DASH=(lc-overview lc-hosts lc-app-jvm lc-data-stores lc-loadtest lc-adserving)
fi

# 접두사로 고른다. 같은 계정에 운영과 부하 시험 환경이 함께 있으면 Role 만으로는 어느 쪽인지 모른다
mon_id() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

TUNNEL_PID=""
cleanup() { [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true; }
trap cleanup EXIT

if [ -n "$LOCAL" ]; then
  curl -sf "http://localhost:$LOCAL_PORT/api/health" > /dev/null 2>&1 || die "localhost:$LOCAL_PORT 에 그라파나가 없다. observability/local 을 띄운다"
  PW=admin
else
  id=$(mon_id)
  [ "$id" != "None" ] && [ -n "$id" ] || die "running 인 $PROJECT 모니터링 인스턴스가 없다"

  log "1. 터널 $LOCAL_PORT -> $id:3000"
  aws ssm start-session --target "$id" --region "$REGION" \
    --document-name AWS-StartPortForwardingSession \
    --parameters "{\"portNumber\":[\"3000\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
    > /dev/null 2>&1 &
  TUNNEL_PID=$!

  deadline=$(( $(date +%s) + 60 ))
  until curl -sf "http://localhost:$LOCAL_PORT/api/health" > /dev/null 2>&1; do
    [ "$(date +%s)" -ge "$deadline" ] && die "터널이 안 열렸다. session-manager-plugin 이 있나"
    kill -0 "$TUNNEL_PID" 2>/dev/null || die "터널 프로세스가 죽었다"
    sleep 2
  done
  log "   열렸다"

  # 비어 있으면 compose 의 기본값이 admin 이다.
  PW=$(aws ssm get-parameter --name "/$PROJECT/grafana-admin-password" --region "$REGION" \
        --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)
  [ -n "$PW" ] && [ "$PW" != "None" ] || PW=admin
fi

stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
if [ -n "$DIAG" ]; then
  dir="$OUT_ROOT"
  prefix="diag-$DIAG-"
else
  dir="$OUT_ROOT/${stamp}${LABEL:+_$LABEL}/grafana"
  prefix=""
fi
mkdir -p "$dir"

# 무엇을 자른 구간인지 남긴다. 파일 이름만으로는 나중에 회차를 못 짚는다.
{
  printf 'label   %s\n' "${LABEL:-없음}"
  printf 'from    %s  (%s)\n' "$FROM" "$(date -u -r $((FROM/1000)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '-')"
  printf 'to      %s  (%s)\n' "$TO" "$(date -u -r $((TO/1000)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '-')"
  printf 'size    %sx%s\n' "$WIDTH" "${HEIGHT:-대시보드 높이}"
} > "$dir/${prefix}구간.txt"

#
# 대시보드 전체가 들어가는 높이를 잰다 (#60).
#
# 렌더러는 준 높이의 화면 하나만 찍는다. 900 으로 고정했을 때 광고 서빙(지금 07)의 아래 패널이 잘렸다.
# 그리드 한 칸이 30px 이고 칸 사이가 8px 이다. 가장 아래 패널의 끝에 키오스크 여백을 더한다.
#
dash_height() {
  curl -sf -u "admin:$PW" "http://localhost:$LOCAL_PORT/api/dashboards/uid/$1" \
    | python3 -c 'import json,sys; p=json.load(sys.stdin)["dashboard"]["panels"]; print(max(x["gridPos"]["y"] + x["gridPos"]["h"] for x in p) * 38 + 64)'
}

log "2. 렌더 $FROM ~ $TO"
ok=0; fail=0
for uid in "${DASH[@]}"; do
  out="$dir/${prefix}$uid.png"
  [ -n "$DIAG" ] && out="$dir/${prefix}overrun.png"
  h="${HEIGHT:-$(dash_height "$uid" || echo 900)}"
  code=$(curl -s -o "$out" -w '%{http_code}' --max-time 180 -u "admin:$PW" \
    "http://localhost:$LOCAL_PORT/render/d/$uid/x?orgId=1&from=$FROM&to=$TO&width=$WIDTH&height=$h&kiosk&tz=Asia%2FSeoul&timeout=120" \
    2>/dev/null || echo 000)
  # 그라파나는 렌더러가 없어도 200 을 주고 본문에 오류를 담는다. 매직 바이트로 가른다.
  if [ "$code" = "200" ] && [ "$(head -c 4 "$out" | od -An -tx1 | tr -d ' \n')" = "89504e47" ]; then
    log "   $uid  ${WIDTH}x$h  $(wc -c < "$out" | tr -d ' ') 바이트"
    ok=$((ok+1))
  else
    log "   $uid  실패 (HTTP $code)"
    head -c 300 "$out" >&2 2>/dev/null || true; printf '\n' >&2
    rm -f "$out"; fail=$((fail+1))
  fi
done

#
# 진단 회차의 Call Tree 와 트레이스 화면이다 (#106).
#
# 렌더러는 URL 을 열어 찍기만 해서 Drilldown 의 Call Tree 를 누르지 못한다. 그래서 브라우저 자동화(Playwright)를 쓴다.
# 팀원 기계에 설치하지 않게 공식 이미지에 얹은 이미지(scripts/diag-capture)를 그때 짓는다. 바뀐 것이 없으면 캐시를 쓴다.
#
if [ -n "$DIAG" ]; then
  log "2-1. 진단 화면 ($DIAG, 트레이스 ${#TRACES[@]} 개)"
  docker build -q -t lunchcatch-diag-capture "$ROOT/scripts/diag-capture" > /dev/null || die "진단 캡처 이미지를 짓지 못했다"
  trace_args=()
  for t in ${TRACES[@]+"${TRACES[@]}"}; do trace_args+=(--trace "$t"); done
  for f in ${EXPANDS[@]+"${EXPANDS[@]}"}; do trace_args+=(--expand "$f"); done
  [ -z "$BASELINE" ] || trace_args+=(--baseline "$BASELINE" --baseline-from "$BASE_FROM" --baseline-to "$BASE_TO")
  for f in ${FIXED[@]+"${FIXED[@]}"}; do trace_args+=(--fixed "$f"); done
  # 비밀번호는 값을 명령행에 두지 않고 환경변수 이름만 넘긴다. 명령행은 도는 동안 프로세스 목록에 보인다
  if GRAFANA_PASSWORD="$PW" docker run --rm -e GRAFANA_PASSWORD -v "$(cd "$dir" && pwd):/out" lunchcatch-diag-capture \
      --grafana "http://localhost:$LOCAL_PORT" --run "$DIAG" --from "$FROM" --to "$TO" --out /out \
      ${trace_args[@]+"${trace_args[@]}"} >&2; then
    ok=$((ok + 2 + ${#TRACES[@]}))
    [ -z "$BASELINE" ] || ok=$((ok + 2))
  else
    log "   진단 화면 실패"
    fail=$((fail+1))
  fi
fi

#
# 진단 회차의 Redis 명령별 서버 처리 시간이다 (#116).
#
# 트레이스의 Redis 스팬은 앱이 보내고 받기까지의 시간이라, 서버에서 쓴 시간인지 앱 쪽에서 기다린 시간인지 가르지 못한다.
# redis-exporter 가 이미 15초마다 모아 둔 지표를 회차가 끝난 뒤 읽기만 하므로 Redis 에 명령을 보내지 않는다.
# 느린 명령의 내용(SLOWLOG GET)은 Redis 에 직접 붙어야 해서 남기지 않고 건수만 남긴다.
#
redis_query() {
  curl -sf -G -u "admin:$PW" "http://localhost:$LOCAL_PORT/api/datasources/proxy/uid/prometheus/api/v1/query" \
    --data-urlencode "query=$1" --data-urlencode "time=$2"
}

if [ -n "$DIAG" ]; then
  log "2-2. Redis 명령별 서버 처리 시간 ($DIAG)"
  w=$(( (TO - FROM) / 1000 ))s
  at=$(( TO / 1000 ))
  out="$dir/${prefix}redis.txt"
  if calls=$(redis_query "sum by (cmd) (increase(redis_commands_total[$w]))" "$at") \
      && spent=$(redis_query "sum by (cmd) (increase(redis_commands_duration_seconds_total[$w]))" "$at") \
      && p99=$(redis_query "histogram_quantile(0.99, sum by (cmd, le) (increase(redis_commands_latencies_usec_bucket[$w])))" "$at") \
      && slow_end=$(redis_query "max(redis_slowlog_last_id)" "$at") \
      && slow_start=$(redis_query "max(redis_slowlog_last_id)" "$(( FROM / 1000 ))"); then
    CALLS="$calls" SPENT="$spent" P99="$p99" SLOW_END="$slow_end" SLOW_START="$slow_start" FROM="$FROM" TO="$TO" python3 - > "$out" <<'PY'
import json, os, unicodedata
from datetime import datetime, timedelta, timezone

def series(name):
    return {r["metric"].get("cmd", ""): float(r["value"][1]) for r in json.loads(os.environ[name])["data"]["result"]}

def scalar(name):
    result = json.loads(os.environ[name])["data"]["result"]
    return int(float(result[0]["value"][1])) if result else None

# 한글은 칸 두 개를 차지한다. 글자 수로 채우면 머리와 값의 열이 어긋난다
def pad(text, width, right=False):
    room = " " * max(0, width - sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text))
    return room + text if right else text + room

kst = timezone(timedelta(hours=9))
when = lambda ms: datetime.fromtimestamp(int(ms) / 1000, kst).strftime("%Y-%m-%d %H:%M:%S")
calls, spent, p99 = series("CALLS"), series("SPENT"), series("P99")
start, end = scalar("SLOW_START"), scalar("SLOW_END")
print(f"구간    {when(os.environ['FROM'])} ~ {when(os.environ['TO'])} (KST)")
print("서버 처리 시간은 Redis 가 명령을 실행한 시간이다. 앱이 보내고 받기까지 기다린 시간은 들지 않는다")
print()
print(pad("명령", 24) + pad("호출 수", 12, True) + pad("서버 평균(ms)", 16, True) + pad("서버 p99(ms)", 16, True))
for cmd, n in sorted(calls.items(), key=lambda kv: -kv[1]):
    if n < 1:
        continue
    q = p99.get(cmd)
    q = f"{q / 1000:.3f}" if q is not None and q == q else "-"
    print(f"{cmd:<24}{n:>12.0f}{spent.get(cmd, 0) * 1000 / n:>16.3f}{q:>16}")
print()
slow = "알 수 없음" if start is None or end is None else f"{end - start} 건"
print(f"느린 명령(slowlog-log-slower-than 을 넘은 명령)  {slow}")
PY
    log "   $(basename "$out")"
    ok=$((ok+1))
  else
    log "   Redis 지표 실패. redis-exporter 가 떠 있는지 보라"
    fail=$((fail+1))
  fi
fi

log "3. $dir"
log "   성공 $ok / 실패 $fail"
[ "$fail" -eq 0 ] || die "$fail 장이 안 나왔다. renderer 컨테이너가 떠 있는지 보라 (docker ps)"

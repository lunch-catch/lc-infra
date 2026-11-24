#!/usr/bin/env bash
#
# 남긴 두 진단 회차의 프로파일 파일로 Diff flame graph 를 찍는다 (lc-infra #209).
# 앞 버전을 다른 날 쟀거나 환경을 내린 뒤에도 앞 버전과 이 버전을 그림으로 견준다.
# 같은 환경에서 이어 재면 진단 회차 때 loadtest-snapshot.sh --diag --baseline 이 바로 찍어 이 명령이 필요 없다.
#
#   ./scripts/loadtest-diff.sh <앞 회차 폴더> <이 회차 폴더> [--fixed <함수>]... [--expand <함수>]...
#   ./scripts/loadtest-diff.sh <버전 폴더>/../impression-v1/v1-run1-profile <버전 폴더>/v2-run1-profile --fixed ImpressionService.record
#
# 하는 일
#   1. 로컬 구성의 그라파나와 Pyroscope 를 다시 보기용 덮어쓰기(compose.replay.yaml, #203)와 함께 띄운다
#   2. 두 회차의 diag-*-profile.tar.gz 를 원래 시각과 run 꼬리표로 올리고, 두 회차가 다 보일 때까지 기다린다
#   3. 앞 회차를 기준으로 한 Diff(wall, cpu)를 서비스마다 찍어 이 회차 폴더의 diff/ 에 넣는다. 두 회차에 다 있는 서비스만 찍는다
#
# --fixed 는 그 버전에서 고친 함수다. 몫이 거의 변하지 않았어도 그 함수까지 가는 경로를 펼쳐 남긴다.
# --expand 를 주지 않으면 Call Tree 맨 위 진입점에서 wall 이 큰 3개를 펼친다. --fixed 가 없으면 나눈 보기의 첫 화면을 찍는다.
# 찍은 뒤에도 구성은 띄워 둔다. 내리려면 observability/local 에서 docker compose -f compose.yaml -f compose.replay.yaml down -v 를 부른다
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL="$ROOT/observability/local"
GRAFANA="http://localhost:${GRAFANA_PORT:-13000}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date +%T)" "$*" >&2; }

[ $# -ge 2 ] || die "앞 회차 폴더와 이 회차 폴더를 준다"
base_dir="$(cd "$1" && pwd)"; run_dir="$(cd "$2" && pwd)"; shift 2
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fixed|--expand) args+=("$1" "${2:?$1 뒤에 함수를 준다}"); shift 2 ;;
    *) die "모르는 선택지다: $1" ;;
  esac
done

window() { awk -v k="$2" '$1 == k {print $2}' "$1/구간.txt"; }
archive() { ls "$1"/diag-*-profile.tar.gz 2> /dev/null | head -1; }
for d in "$base_dir" "$run_dir"; do
  [ -f "$d/구간.txt" ] || die "$d 에 구간.txt 가 없다. 캡처가 만든 진단 회차 폴더를 준다"
  [ -n "$(archive "$d")" ] || die "$d 에 프로파일 파일(diag-*-profile.tar.gz)이 없다"
done
# 프로파일의 run 꼬리표는 보관 파일의 manifest.json 이 갖는다. 폴더 이름은 캡처의 기본 폴더(<시각>_<회차>)처럼 다를 수 있다
run_of() { tar -xzOf "$(archive "$1")" manifest.json | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["run"])'; }
base=$(run_of "$base_dir") || die "$base_dir 의 보관 파일에서 회차 이름을 읽지 못했다"
run=$(run_of "$run_dir") || die "$run_dir 의 보관 파일에서 회차 이름을 읽지 못했다"

log "1. 그라파나와 Pyroscope 를 다시 보기용으로 띄운다"
# 앱을 띄우지 않아 JWT_SECRET 을 쓰지 않는다. compose 가 파일 전체의 변수를 먼저 풀어 .env 가 없으면 자리값을 준다(loadtest-replay.sh 와 같다)
if [ -z "${JWT_SECRET:-}" ] && ! grep -qs '^JWT_SECRET=.' "$LOCAL/.env"; then
  export JWT_SECRET=replay-not-used
fi
(cd "$LOCAL" && docker compose -f compose.yaml -f compose.replay.yaml up -d grafana pyroscope > /dev/null)
for i in $(seq 1 60); do
  curl -sf "$GRAFANA/api/health" > /dev/null 2>&1 && break
  sleep 3
done
curl -sf "$GRAFANA/api/health" > /dev/null || die "그라파나가 뜨지 않았다"
export GRAFANA_PASSWORD=admin
pyro="$GRAFANA/api/datasources/proxy/uid/pyroscope"
# 다시 보기용 설정으로 막 다시 띄운 Pyroscope 는 준비되기 전에 올리면 empty ring 으로 거절한다(500). 준비될 때까지 기다린다
for i in $(seq 1 60); do
  curl -sf -u admin:admin "$pyro/ready" > /dev/null 2>&1 && break
  sleep 3
done
curl -sf -u admin:admin "$pyro/ready" > /dev/null || die "Pyroscope 가 준비되지 않았다"

log "2. 두 회차의 프로파일을 올린다"
for d in "$base_dir" "$run_dir"; do
  python3 -I "$ROOT/scripts/diag-capture/profiles.py" restore --pyroscope "$pyro" --archive "$(archive "$d")" >&2
done
# 지난 시각으로 올린 프로파일은 보이기까지 1 ~ 2분 걸리고 cpu 와 wall 이 따로 보이기 시작한다. 두 회차의 앱 wall 과 cpu 가 다 보일 때까지 기다린다
visible() {
  local r="$1" from="$2" to="$3" id
  for id in wall:wall:nanoseconds:cpu:nanoseconds process_cpu:cpu:nanoseconds:cpu:nanoseconds; do
    curl -sf -u admin:admin -X POST "$pyro/querier.v1.QuerierService/SelectMergeStacktraces" -H 'Content-Type: application/json' \
      -d "{\"profileTypeID\":\"$id\",\"labelSelector\":\"{service_name=\\\"lunchcatch\\\",run=\\\"$r\\\"}\",\"start\":$from,\"end\":$to}" \
      | python3 -I -c 'import json,sys; sys.exit(0 if int((json.load(sys.stdin).get("flamegraph") or {}).get("total") or 0) > 0 else 1)' || return 1
  done
  # Diff 화면은 그 구간의 프로파일 종류 목록으로 종류를 고른다. 목록은 데이터보다 늦게 잡혀, 목록에 wall 과 cpu 가 다 나올 때까지 기다린다
  curl -sf -u admin:admin -X POST "$pyro/querier.v1.QuerierService/LabelValues" -H 'Content-Type: application/json' \
    -d "{\"name\":\"__profile_type__\",\"matchers\":[\"{service_name=\\\"lunchcatch\\\",run=\\\"$r\\\"}\"],\"start\":$from,\"end\":$to}" \
    | python3 -I -c 'import json,sys; n=set(json.load(sys.stdin).get("names",[])); sys.exit(0 if {"wall:wall:nanoseconds:cpu:nanoseconds","process_cpu:cpu:nanoseconds:cpu:nanoseconds"} <= n else 1)'
}
bf=$(window "$base_dir" from); bt=$(window "$base_dir" to); rf=$(window "$run_dir" from); rt=$(window "$run_dir" to)
for i in $(seq 1 40); do
  visible "$base" "$bf" "$bt" && visible "$run" "$rf" "$rt" && break
  [ "$i" -lt 40 ] || die "올린 프로파일이 10분 안에 보이지 않았다"
  sleep 15
done

log "3. Diff 를 찍는다 ($base -> $run)"
docker build -q -t lunchcatch-diag-capture "$ROOT/scripts/diag-capture" > /dev/null || die "진단 캡처 이미지를 짓지 못했다"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
docker run --rm -e GRAFANA_PASSWORD -v "$work:/out" lunchcatch-diag-capture \
  --grafana "$GRAFANA" --run "$run" --from "$rf" --to "$rt" --out /out --diff-only --trace-top 0 \
  --baseline "$base" --baseline-from "$bf" --baseline-to "$bt" ${args[@]+"${args[@]}"} >&2
[ -n "$(ls "$work"/diff/*.png 2> /dev/null)" ] || die "Diff 를 찍지 못했다"
mkdir -p "$run_dir/diff"
cp "$work"/diff/*.png "$run_dir/diff/"
log "   $(cd "$run_dir" && ls diff/*.png | tr '\n' ' ')"

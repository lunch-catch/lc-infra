#!/usr/bin/env bash
#
# 남긴 진단 회차를 노트북의 로컬 구성에서 그라파나로 다시 본다 (lc-infra #203).
# 부하 시험 환경을 내린 뒤에도 그 회차의 대시보드, 로그, 프로파일을 원래 시각으로 본다.
#
#   ./scripts/loadtest-replay.sh <회차 폴더>
#   ./scripts/loadtest-replay.sh <lc-backend>/docs/design/adserving/loadtest/impression-v1/v1-run1-profile
#
# 하는 일
#   1. 로컬 구성의 관측 도구(그라파나, Prometheus, Loki, Tempo, Pyroscope, Alloy)를 다시 보기용 덮어쓰기(compose.replay.yaml)와 함께 띄운다.
#      덮어쓰기는 지난 시각의 지표, 로그, 트레이스를 지우거나 거절하지 않게만 한다. 앱은 띄우지 않는다
#   2. metrics.json.gz 를 promtool 로 블록으로 만들어 Prometheus 에 넣는다
#   3. logs.jsonl.gz 를 Loki 에 넣는다
#   4. diag-*-profile.tar.gz 를 Pyroscope 에 넣는다
#   5. traces/*/trace.json 을 Alloy 를 거쳐 Tempo 에 넣는다(#219). 판정 패널의 트레이스 링크가 남긴 트레이스를 찾는다
#   6. 그 회차 구간의 그라파나 주소를 출력한다
#
# 한 번에 한 회차만 본다. 다른 회차를 보려면 먼저 내린다(docker compose -f compose.yaml -f compose.replay.yaml down -v)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL="$ROOT/observability/local"
PROJECT=lunchcatch-local
GRAFANA="http://localhost:${GRAFANA_PORT:-13000}"
PROM_IMAGE=prom/prometheus:v3.13.1

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date +%T)" "$*" >&2; }

run_dir="${1:?회차 폴더를 준다}"
run_dir="$(cd "$run_dir" && pwd)"
[ -f "$run_dir/구간.txt" ] || die "$run_dir 에 구간.txt 가 없다. 캡처가 만든 회차 폴더를 준다"
from=$(awk '$1 == "from" {print $2}' "$run_dir/구간.txt")
to=$(awk '$1 == "to" {print $2}' "$run_dir/구간.txt")
[ -n "$from" ] && [ -n "$to" ] || die "구간.txt 에서 from 과 to 를 읽지 못했다"

log "1. 관측 도구를 다시 보기용으로 띄운다"
# compose 는 띄울 서비스를 고르기 전에 파일 전체의 변수를 푼다. 앱의 JWT_SECRET 은 없으면 멈추게 되어 있어(compose.yaml),
# .env 가 없는 기계에서도 뜨게 자리값을 준다. 다시 보기는 앱을 띄우지 않아 이 값을 쓰지 않는다
if [ -z "${JWT_SECRET:-}" ] && ! grep -qs '^JWT_SECRET=.' "$LOCAL/.env"; then
  export JWT_SECRET=replay-not-used
fi
(cd "$LOCAL" && docker compose -f compose.yaml -f compose.replay.yaml up -d grafana prometheus loki tempo pyroscope alloy > /dev/null)
for i in $(seq 1 60); do
  curl -sf "$GRAFANA/api/health" > /dev/null 2>&1 \
    && curl -sf -u admin:admin "$GRAFANA/api/datasources/proxy/uid/loki/ready" > /dev/null 2>&1 && break
  sleep 3
done
curl -sf "$GRAFANA/api/health" > /dev/null || die "그라파나가 뜨지 않았다"
export GRAFANA_PASSWORD=admin

if [ -f "$run_dir/metrics.json.gz" ]; then
  log "2. 지표"
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  python3 -I "$ROOT/scripts/diag-capture/telemetry.py" om --dir "$run_dir" --out "$work/metrics.om" >&2
  docker run --rm -v "$work:/w" --entrypoint promtool "$PROM_IMAGE" \
    tsdb create-blocks-from openmetrics /w/metrics.om /w/blocks > /dev/null
  prom="$PROJECT-prometheus-1"
  # 이미지의 저장 폴더는 /prometheus/data 다(--storage.tsdb.path 의 기본값 data/, 작업 폴더 /prometheus)
  for b in "$work"/blocks/*/; do
    docker cp "$b" "$prom:/prometheus/data/" > /dev/null
  done
  # docker cp 는 root 로 넣는다. Prometheus 는 nobody 로 돌며 블록을 다시 묶고 지운다
  docker exec -u 0 "$prom" chown -R nobody:nobody /prometheus/data
  docker restart "$prom" > /dev/null
  log "   블록 $(ls -d "$work"/blocks/*/ | wc -l | tr -d ' ') 개"
else
  log "2. 지표: metrics.json.gz 가 없어 건너뛴다"
fi

if [ -f "$run_dir/logs.jsonl.gz" ]; then
  log "3. 로그"
  python3 -I "$ROOT/scripts/diag-capture/telemetry.py" logs --grafana "$GRAFANA" --dir "$run_dir" >&2
else
  log "3. 로그: logs.jsonl.gz 가 없어 건너뛴다"
fi

profile=$(ls "$run_dir"/diag-*-profile.tar.gz 2> /dev/null | head -1 || true)
if [ -n "$profile" ]; then
  log "4. 프로파일"
  python3 -I "$ROOT/scripts/diag-capture/profiles.py" restore \
    --pyroscope "$GRAFANA/api/datasources/proxy/uid/pyroscope" --archive "$profile" >&2
else
  log "4. 프로파일: 파일이 없어 건너뛴다"
fi

if ls "$run_dir"/traces/*/trace.json > /dev/null 2>&1; then
  log "5. 트레이스"
  # 다시 보기용 Alloy 가 OTLP HTTP 를 이 포트로 연다(compose.replay.yaml)
  otlp="http://localhost:${REPLAY_OTLP_PORT:-14318}"
  for i in $(seq 1 30); do
    curl -sf -X POST -H 'Content-Type: application/json' -d '{"resourceSpans":[]}' "$otlp/v1/traces" > /dev/null 2>&1 && break
    sleep 2
  done
  python3 -I "$ROOT/scripts/diag-capture/telemetry.py" traces --otlp "$otlp" --dir "$run_dir" >&2
else
  log "5. 트레이스: 남긴 트레이스가 없어 건너뛴다"
fi

log "6. 다시 보기"
echo "그라파나  $GRAFANA/dashboards?from=$from&to=$to  (admin/admin). 대시보드를 열면 이 구간이다"
echo "          지난 시각으로 넣은 지표와 프로파일은 보이기까지 1 ~ 2분, 트레이스는 테일 샘플링의 판정 대기(10초) 뒤에 보인다"
echo "          판정 패널의 트레이스 링크는 남긴 트레이스(traces.txt)만 찾는다. 남기지 않은 트레이스는 나오지 않는다"

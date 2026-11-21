"""
부하 시험 회차에서 찍을 트레이스를 고르고, 그 트레이스의 로그를 글로 남긴다(lc-infra #187).

브라우저 없이 Grafana 의 데이터 소스 프록시로 Prometheus, Tempo, Loki 를 읽는다. 도메인을 가리지 않는다.
API 마다 앱이 내보내는 기준(overrun_threshold_seconds{kind="api"})을 넘은 서버 스팬을 찾아 오래 걸린 순으로 고른다.
"""
import json
import urllib.parse
import urllib.request

# Tempo 검색은 걸린 시간 순으로 돌려주지 않는다. 기준을 넘은 트레이스를 이만큼 받아 그 안에서 오래 걸린 순으로 고른다.
# 테일 샘플링이 느린 트레이스를 남겨 한 회차에 기준을 넘은 트레이스가 이보다 많으면 가장 느린 것을 놓칠 수 있다
SEARCH_LIMIT = 500
# 로그 화면과 같은 쿼리다. Grafana 의 트레이스 -> 로그 연결(datasources.yml 의 tracesToLogsV2)과 같게 둔다
LOG_QUERY = '{{container=~"lunchcatch.*"}} |= "{trace_id}"'
LOG_LIMIT = 1000


class Grafana:
    def __init__(self, base, auth):
        self.base = base.rstrip("/")
        self.auth = auth

    def get(self, path, params):
        url = f"{self.base}{path}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, headers={"Authorization": self.auth})
        with urllib.request.urlopen(req, timeout=60) as res:
            return json.load(res)

    def prometheus(self, query, at):
        body = self.get("/api/datasources/proxy/uid/prometheus/api/v1/query", {"query": query, "time": at})
        return body["data"]["result"]

    def tempo_search(self, traceql, start, end):
        body = self.get("/api/datasources/proxy/uid/tempo/api/search",
                        {"q": traceql, "start": start, "end": end, "limit": SEARCH_LIMIT, "spss": 1})
        return body.get("traces") or []

    def loki_lines(self, trace_id, start_ns, end_ns):
        body = self.get("/api/datasources/proxy/uid/loki/loki/api/v1/query_range",
                        {"query": LOG_QUERY.format(trace_id=trace_id), "start": start_ns, "end": end_ns,
                         "limit": LOG_LIMIT, "direction": "forward"})
        lines = [(int(ts), line) for stream in body["data"]["result"] for ts, line in stream["values"]]
        return sorted(lines)


def requested_apis(results):
    # http_server_requests 의 method 와 uri 를 스팬 이름(에이전트가 붙이는 "GET /v1/feed")과 같은 꼴로 바꾼다
    return sorted(f'{r["metric"]["method"]} {r["metric"]["uri"]}' for r in results)


def thresholds(results):
    return {r["metric"]["name"]: float(r["value"][1]) for r in results}


def span_seconds(trace):
    # 검색이 맞춘 서버 스팬의 시간이다. 없으면 트레이스 전체 시간을 쓴다
    spans = [s for spanset in trace.get("spanSets") or [trace.get("spanSet") or {}] for s in spanset.get("spans", [])]
    nanos = [int(s["durationNanos"]) for s in spans if s.get("durationNanos")]
    return max(nanos) / 1e9 if nanos else trace.get("durationMs", 0) / 1000


def traceql(api, threshold):
    return f'{{ kind = server && name = "{api}" && duration > {threshold * 1000:g}ms }}'


def pick(apis, limits, search, top):
    """
    API 마다 기준을 넘은 트레이스를 오래 걸린 순으로 top 개 고른다. 기준을 넘은 것이 없는 API 는 고르지 않는다.
    search 는 TraceQL 을 받아 Tempo 의 검색 결과를 돌려준다. 이름별 기준이 없으면 default 를 쓴다
    """
    chosen = []
    for api in apis:
        limit = limits.get(api, limits.get("default"))
        if limit is None:
            continue
        found = sorted(search(traceql(api, limit)), key=span_seconds, reverse=True)[:top]
        # Tempo 는 트레이스 ID 의 앞자리 0 을 떼고 돌려준다. 로그의 trace_id 와 같게 32자리로 채운다
        chosen += [{"api": api, "threshold": limit, "seconds": span_seconds(t), "trace_id": t["traceID"].rjust(32, "0")}
                   for t in found]
    return chosen


def select(grafana, frm, to, top):
    """
    회차 구간(유닉스 밀리초)에서 찍을 트레이스를 고른다. 고르지 못한 이유가 있으면 함께 돌려준다
    """
    window = f"{max(1, (int(to) - int(frm)) // 1000)}s"
    at = int(to) / 1000
    limits = thresholds(grafana.prometheus('max by (name) (overrun_threshold_seconds{kind="api"})', at))
    if not limits:
        return [], "앱이 기준(overrun_threshold_seconds)을 내보내지 않아 고르지 않았다"
    apis = requested_apis(grafana.prometheus(
        'sum by (method, uri) (increase(http_server_requests_seconds_count{uri!~"UNKNOWN|root|/actuator.*"}['
        + window + '])) > 0', at))
    start, end = int(frm) // 1000, int(to) // 1000 + 1
    chosen = pick(apis, limits, lambda q: grafana.tempo_search(q, start, end), top)
    return chosen, None if chosen else "기준을 넘은 요청의 트레이스가 없다"


def write_list(path, chosen, note):
    with open(path, "w") as f:
        f.write("번호\tAPI\t기준(ms)\t걸린 시간(ms)\t트레이스 ID\n")
        for n, t in enumerate(chosen, start=1):
            f.write(f'{n}\t{t["api"]}\t{t["threshold"] * 1000:g}\t{t["seconds"] * 1000:.1f}\t{t["trace_id"]}\n')
        if note:
            f.write(f"\n{note}\n")


def write_logs(path, grafana, trace_id, frm, to):
    lines = grafana.loki_lines(trace_id, int(frm) * 1_000_000, int(to) * 1_000_000)
    with open(path, "w") as f:
        f.write(f"트레이스 {trace_id} 의 로그 {len(lines)} 줄. 쿼리 {LOG_QUERY.format(trace_id=trace_id)}\n\n")
        for _, line in lines:
            f.write(line.rstrip("\n") + "\n")
    return len(lines)

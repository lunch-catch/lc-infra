"""
부하 시험 회차에서 찍을 트레이스를 고르고, 그 트레이스의 로그를 글로 남긴다(lc-infra #187, #189).

브라우저 없이 Grafana 의 API 와 데이터 소스 프록시로 읽는다. 도메인을 가리지 않는다.
판정과 고를 트레이스는 대시보드가 갖는다. API 와 백그라운드 작업 대시보드의 "기준을 넘은" 패널마다
그 판정식이 회차 구간에 한 번이라도 낸 줄(API, 릴레이, 워커, 작업)을 찾고, 그 패널의 트레이스 링크가 여는
TraceQL 로 오래 걸린 트레이스를 고른다. 식과 링크를 여기 다시 적지 않아 대시보드를 고치면 캡처도 따라간다.
"""
import json
import re
import urllib.parse
import urllib.request

DASHBOARDS = ["lc-api", "lc-background"]
# 판정 패널을 제목으로 고른다. 두 대시보드의 판정 패널 제목은 모두 이 말로 시작한다
JUDGE_TITLE = "기준을 넘은"
# 대시보드가 그리는 시계열을 구간 전체에서 훑는 간격이다. Prometheus 의 수집 간격과 같다
STEP = "15s"
# $__rate_interval 자리에 넣는다. 수집 간격(15초)의 4배로 Grafana 가 고르는 값과 같다
RATE_INTERVAL = "1m"
# Tempo 검색은 걸린 시간 순으로 돌려주지 않는다. 이만큼 받아 그 안에서 오래 걸린 순으로 고른다.
# 한 줄에 맞는 트레이스가 이보다 많으면 가장 느린 것을 놓칠 수 있다
SEARCH_LIMIT = 500
# 로그 화면과 같은 쿼리다. Grafana 의 트레이스 -> 로그 연결(datasources.yml 의 tracesToLogsV2)과 같게 둔다
LOG_QUERY = '{{container=~"lunchcatch.*"}} |= "{trace_id}"'
LOG_LIMIT = 1000
FIELD_LABEL = re.compile(r"\$\{__field\.labels\.([A-Za-z_][A-Za-z0-9_]*)(?::[a-z]+)?\}")


class Grafana:
    def __init__(self, base, auth):
        self.base = base.rstrip("/")
        self.auth = auth

    def get(self, path, params=None):
        url = f"{self.base}{path}" + (f"?{urllib.parse.urlencode(params)}" if params else "")
        req = urllib.request.Request(url, headers={"Authorization": self.auth})
        with urllib.request.urlopen(req, timeout=60) as res:
            return json.load(res)

    def dashboard(self, uid):
        return self.get(f"/api/dashboards/uid/{uid}")["dashboard"]

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


def panels(dashboard):
    for panel in dashboard.get("panels", []):
        yield panel
        yield from panels(panel)


def tempo_links(node):
    if isinstance(node, dict):
        if "tempo" in str(node.get("url", "")):
            yield node
        for value in node.values():
            yield from tempo_links(value)
    elif isinstance(node, list):
        for value in node:
            yield from tempo_links(value)


def traceql_of(link):
    panes = json.loads(urllib.parse.unquote(link["url"].split("panes=", 1)[1].split("&", 1)[0]))
    return next(iter(panes.values()))["queries"][0]["query"]


def judges(dashboard):
    """
    판정 패널마다 판정식들과 트레이스 링크의 TraceQL 을 돌려준다. 링크가 없는 판정 패널은 고를 트레이스가 없어 뺀다
    """
    for panel in panels(dashboard):
        links = list(tempo_links(panel.get("fieldConfig", {})))
        if not panel.get("title", "").startswith(JUDGE_TITLE) or not links:
            continue
        exprs = [t["expr"] for t in panel.get("targets", []) if t.get("expr") and not t.get("hide")]
        yield panel["title"], exprs, traceql_of(links[0])


def fill(template, labels):
    # 링크의 ${__field.labels.X:percentencode} 를 그 줄의 라벨 값으로 채운다. TraceQL 에 넣으므로 인코딩하지 않는다
    missing = [name for name in FIELD_LABEL.findall(template) if name not in labels]
    if missing:
        return None
    return FIELD_LABEL.sub(lambda m: labels[m.group(1)].replace('"', '\\"'), template)


def span_seconds(trace):
    # 검색이 맞춘 스팬의 시간이다. 없으면 트레이스 전체 시간을 쓴다
    spans = [s for spanset in trace.get("spanSets") or [trace.get("spanSet") or {}] for s in spanset.get("spans", [])]
    nanos = [int(s["durationNanos"]) for s in spans if s.get("durationNanos")]
    return max(nanos) / 1e9 if nanos else trace.get("durationMs", 0) / 1000


def describe(labels, template):
    shown = FIELD_LABEL.findall(template)
    return ", ".join(f"{k}={labels[k]}" for k in shown if k in labels) or "-"


def pick(judged, search, top):
    """
    judged 는 (패널 제목, 줄의 라벨, 판정 값, 링크의 TraceQL) 들이다. 줄마다 링크의 TraceQL 로 찾아 오래 걸린 순으로 top 개 고른다.
    같은 트레이스가 여러 줄에 걸리면 처음 한 번만 고른다
    """
    chosen, seen = [], set()
    for title, labels, value, template in judged:
        query = fill(template, labels)
        if query is None:
            continue
        found = sorted(search(query), key=span_seconds, reverse=True)
        picked = 0
        for t in found:
            # Tempo 는 트레이스 ID 의 앞자리 0 을 떼고 돌려준다. 로그의 trace_id 와 같게 32자리로 채운다
            trace_id = t["traceID"].rjust(32, "0")
            if trace_id in seen:
                continue
            seen.add(trace_id)
            chosen.append({"panel": title, "target": describe(labels, template), "value": value,
                           "seconds": span_seconds(t), "trace_id": trace_id})
            picked += 1
            if picked == top:
                break
    return chosen


def judge(grafana, frm, to):
    """
    판정 패널의 식을 회차 구간 전체에서 훑어, 한 번이라도 값이 나온 줄과 그 구간의 최댓값을 돌려준다
    """
    window = f"{max(1, (int(to) - int(frm)) // 1000)}s"
    at = int(to) / 1000
    judged = []
    for uid in DASHBOARDS:
        for title, exprs, template in judges(grafana.dashboard(uid)):
            for expr in exprs:
                query = f"max_over_time(({expr.replace('$__rate_interval', RATE_INTERVAL)})[{window}:{STEP}])"
                for row in grafana.prometheus(query, at):
                    judged.append((title, row["metric"], float(row["value"][1]), template))
    return judged


def select(grafana, frm, to, top):
    """
    회차 구간(유닉스 밀리초)에서 찍을 트레이스를 고른다. 고르지 못한 이유가 있으면 함께 돌려준다
    """
    judged = judge(grafana, frm, to)
    if not judged:
        return [], "기준을 넘은 API 와 백그라운드 작업이 없다"
    start, end = int(frm) // 1000, int(to) // 1000 + 1
    chosen = pick(judged, lambda q: grafana.tempo_search(q, start, end), top)
    return chosen, None if chosen else "기준을 넘은 것은 있지만 그 트레이스가 없다. 트레이싱을 켰는지 본다"


def write_list(path, chosen, note):
    with open(path, "w") as f:
        f.write("번호\t패널\t대상\t판정 값(구간 최댓값)\t걸린 시간(ms)\t트레이스 ID\n")
        for n, t in enumerate(chosen, start=1):
            f.write(f'{n}\t{t["panel"]}\t{t["target"]}\t{t["value"]:.3g}\t{t["seconds"] * 1000:.1f}\t{t["trace_id"]}\n')
        if note:
            f.write(f"\n{note}\n")


def write_logs(path, grafana, trace_id, frm, to):
    lines = grafana.loki_lines(trace_id, int(frm) * 1_000_000, int(to) * 1_000_000)
    with open(path, "w") as f:
        f.write(f"트레이스 {trace_id} 의 로그 {len(lines)} 줄. 쿼리 {LOG_QUERY.format(trace_id=trace_id)}\n\n")
        for _, line in lines:
            f.write(line.rstrip("\n") + "\n")
    return len(lines)

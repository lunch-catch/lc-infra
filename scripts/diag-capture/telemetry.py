#!/usr/bin/env python3
#
# 진단 회차의 지표, 로그, 트레이스 원본을 회차 폴더에 남기고, 다시 볼 때 로컬 구성에 넣는다 (#203).
# 환경을 내리면 Prometheus, Loki, Tempo 의 기록이 함께 사라져 그 회차를 그라파나에서 다시 볼 수 없어서다.
#
#   telemetry.py export  --grafana <주소> --dir <회차 폴더> --from <ms> --to <ms> --dashboards <대시보드 폴더>
#   telemetry.py logs    --grafana <주소> --dir <회차 폴더>        남긴 로그를 Loki 에 넣는다
#   telemetry.py om      --dir <회차 폴더> --out <파일>             남긴 지표를 promtool 이 읽는 OpenMetrics 글로 푼다
#
# 그라파나 주소의 데이터 소스 프록시(/api/datasources/proxy/uid/<uid>)로 묻는다. 부하 시험 환경은 캡처가 연 터널이다.
# 그라파나 비밀번호는 환경변수 GRAFANA_PASSWORD 로 받는다.
#
#   트레이스  traces/<번호>-<대상>/trace.json  traces.txt 에 고른 트레이스의 Tempo 원본이다. 그라파나 Explore 의 Tempo 에서 Import trace 로 연다
#   지표      metrics.json.gz                  우리 대시보드의 식이 쓰는 지표 이름만, 회차 구간의 표본 그대로다
#   로그      logs.jsonl.gz                    앱과 배치의 경고와 오류 로그다. 한 줄이 흐름 하나(꼬리표와 값들)다
#
import argparse
import base64
import glob
import gzip
import json
import os
import re
import sys
import urllib.parse
import urllib.request

LOG_QUERY = '{container=~"lunchcatch.*"} |~ "\\"level\\":\\"(WARN|ERROR)\\""'
LOG_PAGE = 5000


def request(base, path, body=None, content_type=None, accept=None):
    req = urllib.request.Request(base.rstrip("/") + path, data=body)
    if content_type:
        req.add_header("Content-Type", content_type)
    if accept:
        req.add_header("Accept", accept)
    password = os.environ.get("GRAFANA_PASSWORD")
    if password:
        req.add_header("Authorization", "Basic " + base64.b64encode(f"admin:{password}".encode()).decode())
    with urllib.request.urlopen(req, timeout=300) as r:
        return r.read()


def proxy(grafana, uid):
    return grafana.rstrip("/") + "/api/datasources/proxy/uid/" + uid


def write_atomic(path, data):
    # 다 쓴 뒤에 바꿔 끼운다. 쓰다 멈추면 같은 경로의 앞 파일이 그대로 남는다
    with open(path + ".tmp", "wb") as f:
        f.write(data)
    os.replace(path + ".tmp", path)


def export_traces(grafana, run_dir):
    listing = os.path.join(run_dir, "traces.txt")
    if not os.path.exists(listing):
        return 0
    n = 0
    for line in open(listing, encoding="utf-8").read().splitlines()[1:]:
        cols = line.split("\t")
        if len(cols) < 7 or not os.path.isdir(os.path.join(run_dir, cols[1])):
            continue
        data = request(proxy(grafana, "tempo"), "/api/traces/" + cols[6], accept="application/json")
        write_atomic(os.path.join(run_dir, cols[1], "trace.json"), data)
        n += 1
    return n


def dashboard_names(folder):
    # 식에 나오는 낱말 가운데 Prometheus 에 실제로 있는 지표 이름만 남긴다. 함수와 꼬리표 이름은 거기서 걸러진다
    words = set()
    for f in glob.glob(os.path.join(folder, "**", "*.json"), recursive=True):
        text = json.dumps(json.load(open(f, encoding="utf-8")), ensure_ascii=False)
        for expr in re.findall(r'"expr": "((?:[^"\\]|\\.)*)"', text):
            words.update(re.findall(r"[a-zA-Z_:][a-zA-Z0-9_:]*", json.loads('"' + expr + '"')))
    return words


def export_metrics(grafana, run_dir, frm, to, folder):
    base = proxy(grafana, "prometheus")
    start, end = frm / 1000, to / 1000
    q = urllib.parse.urlencode({"start": start, "end": end})
    present = set(json.loads(request(base, "/api/v1/label/__name__/values?" + q))["data"])
    names = sorted(dashboard_names(folder) & present)
    window = max(int(end - start), 1)
    series, samples, skipped = [], 0, 0
    for name in names:
        query = urllib.parse.urlencode({"query": '{__name__="%s"}[%ds]' % (name, window), "time": end})
        for r in json.loads(request(base, "/api/v1/query?" + query))["data"]["result"]:
            values = r.get("values") or []
            if not values:
                # 네이티브 히스토그램(k6 의 지연)은 OpenMetrics 글로 옮기지 못해 건너뛴다
                skipped += 1
                continue
            series.append({"metric": r["metric"], "values": values})
            samples += len(values)
    write_atomic(os.path.join(run_dir, "metrics.json.gz"),
                 gzip.compress(json.dumps({"from": frm, "to": to, "series": series}, separators=(",", ":")).encode()))
    return len(names), len(series), samples, skipped


def export_logs(grafana, run_dir, frm, to):
    base = proxy(grafana, "loki")
    start, end, streams, lines = frm * 1_000_000, to * 1_000_000, {}, 0
    while start < end:
        q = urllib.parse.urlencode({"query": LOG_QUERY, "start": start, "end": end, "limit": LOG_PAGE, "direction": "forward"})
        result = json.loads(request(base, "/loki/api/v1/query_range?" + q))["data"]["result"]
        last, got = None, 0
        for s in result:
            key = json.dumps(s["stream"], sort_keys=True)
            streams.setdefault(key, []).extend(s["values"])
            got += len(s["values"])
            for ts, _ in s["values"]:
                last = max(last or 0, int(ts))
        lines += got
        if got < LOG_PAGE or last is None:
            break
        # 같은 나노초에 줄이 몰려 한 쪽이 끝나면 그 시각의 나머지를 놓칠 수 있다. 경고와 오류만이라 드물다
        start = last + 1
    body = "".join(json.dumps({"stream": json.loads(k), "values": v}, ensure_ascii=False) + "\n" for k, v in streams.items())
    write_atomic(os.path.join(run_dir, "logs.jsonl.gz"), gzip.compress(body.encode()))
    return len(streams), lines


def export(args):
    traces = export_traces(args.grafana, args.dir)
    print(f"telemetry traces {traces} 개")
    names, series, samples, skipped = export_metrics(args.grafana, args.dir, args.from_ms, args.to_ms, args.dashboards)
    print(f"telemetry metrics 지표 {names} 개, 시계열 {series} 개, 표본 {samples} 개 (네이티브 히스토그램 {skipped} 개는 건너뜀)")
    streams, lines = export_logs(args.grafana, args.dir, args.from_ms, args.to_ms)
    print(f"telemetry logs 흐름 {streams} 개, 줄 {lines} 개")
    return 0


def escape(v):
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def om(args):
    data = json.loads(gzip.decompress(open(os.path.join(args.dir, "metrics.json.gz"), "rb").read()))
    families = {}
    for s in data["series"]:
        families.setdefault(s["metric"].get("__name__"), []).append(s)
    with open(args.out, "w", encoding="utf-8") as f:
        # promtool 은 같은 이름의 줄이 이어져 있기를 바란다. 이름마다 모아 쓴다
        for name, rows in families.items():
            for s in rows:
                labels = ",".join(f'{k}="{escape(v)}"' for k, v in sorted(s["metric"].items()) if k != "__name__")
                head = f"{name}{{{labels}}}" if labels else name
                for ts, v in s["values"]:
                    f.write(f"{head} {v} {ts}\n")
        f.write("# EOF\n")
    print(f"telemetry om {len(families)} 개 지표 -> {args.out}")
    return 0


def logs(args):
    path = os.path.join(args.dir, "logs.jsonl.gz")
    if not os.path.exists(path):
        print("telemetry logs 남긴 로그가 없다")
        return 0
    base, n = proxy(args.grafana, "loki"), 0
    for line in gzip.decompress(open(path, "rb").read()).decode().splitlines():
        s = json.loads(line)
        values = sorted(s["values"], key=lambda v: int(v[0]))
        for i in range(0, len(values), 1000):
            body = json.dumps({"streams": [{"stream": s["stream"], "values": values[i:i + 1000]}]}).encode()
            request(base, "/loki/api/v1/push", body, "application/json")
        n += len(values)
    # 지난 시각의 로그는 인제스터가 저장소로 흘려보내기 전에는 질의에 나오지 않는다. 최근 3시간만 인제스터에 묻기 때문이다(query_ingesters_within)
    request(base, "/flush", b"")
    print(f"telemetry logs {n} 줄을 넣고 저장소로 흘려보냈다")
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export")
    e.add_argument("--grafana", required=True)
    e.add_argument("--dir", required=True)
    e.add_argument("--from", dest="from_ms", type=int, required=True)
    e.add_argument("--to", dest="to_ms", type=int, required=True)
    e.add_argument("--dashboards", required=True)
    o = sub.add_parser("om")
    o.add_argument("--dir", required=True)
    o.add_argument("--out", required=True)
    lg = sub.add_parser("logs")
    lg.add_argument("--grafana", required=True)
    lg.add_argument("--dir", required=True)
    args = p.parse_args()
    sys.exit({"export": export, "om": om, "logs": logs}[args.cmd](args))


if __name__ == "__main__":
    main()

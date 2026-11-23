#!/usr/bin/env python3
#
# 진단 회차의 프로파일을 Pyroscope 에서 꺼내 파일 하나로 남기고, 그 파일을 다시 Pyroscope 에 올린다 (#199).
# 환경을 내리면 Pyroscope 와 함께 프로파일이 사라져, 다른 날 잰 다음 버전과 Diff 로 견줄 수 없어서다.
#
#   profiles.py export  --pyroscope <주소> --run <회차> --from <ms> --to <ms> --out <파일.tar.gz>
#   profiles.py restore --pyroscope <주소> --archive <파일.tar.gz>
#
# 주소는 Pyroscope 의 HTTP 주소다. 캡처는 그라파나의 데이터 소스 프록시(.../api/datasources/proxy/uid/pyroscope)를 준다.
# 그라파나 비밀번호는 환경변수 GRAFANA_PASSWORD 로 받는다. 없으면 인증 없이 묻는다.
#
# 앱은 10초씩 떠서 그 묶음을 시작 시각(초) 한 점으로 보낸다(lunch-catch/lc-backend 의 loadtest/lib/common.sh, PROFILE_SH).
# 그래서 묶음이 찍힌 초를 시계열 질의로 찾고, 그 초를 1ms 앞뒤로 걸친 창으로 물어 묶음 하나씩 꺼낸다. 앱 서버가 여럿이면 같은 초에 찍힌 묶음은 합쳐진다.
# 시계열이 돌려주는 시각은 시작 시각을 맞추는 방식에 따라 한 칸 어긋나, 그 앞뒤 한 초도 함께 묻는다. 빈 초는 버린다.
# 한 초 안에서 끝나는 창은 Pyroscope 가 경계를 초로 맞추며 "시작이 끝보다 늦다" 로 막기도 해서 초 경계를 걸친다.
# 옛 질의(/pyroscope/render)는 시각을 초와 밀리초로 어림해 읽어 쓰지 않는다.
# 받은 값은 나노초라 보낼 때의 표본 간격으로 나눠 표본 수로 되돌린다. 보낼 때와 같은 꼴(folded)이라 그대로 다시 올린다.
#
import argparse
import base64
import io
import json
import os
import sys
import tarfile
import time
import urllib.parse
import urllib.request

SERVICE = "lunchcatch"
# 종류마다 Pyroscope 의 프로파일 종류와 보낼 때의 초당 표본 수다. 표본 수는 PROFILE_SH 의 send 와 같아야 한다
KINDS = {
    "cpu": ("process_cpu:cpu:nanoseconds:cpu:nanoseconds", 100),
    "wall": ("wall:wall:nanoseconds:cpu:nanoseconds", 20),
}


def request(base, path, body=None, content_type=None):
    req = urllib.request.Request(base.rstrip("/") + path, data=body)
    if content_type:
        req.add_header("Content-Type", content_type)
    password = os.environ.get("GRAFANA_PASSWORD")
    if password:
        req.add_header("Authorization", "Basic " + base64.b64encode(f"admin:{password}".encode()).decode())
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def selector(run):
    return '{service_name="%s",run="%s"}' % (SERVICE, run)


def query(base, kind, run, start_ms, end_ms, path, **extra):
    body = dict({"profileTypeID": KINDS[kind][0], "labelSelector": selector(run), "start": start_ms, "end": end_ms}, **extra)
    return json.loads(request(base, "/querier.v1.QuerierService/" + path, json.dumps(body).encode(), "application/json"))


def candidate_seconds(base, kind, run, start_ms, end_ms):
    data = query(base, kind, run, start_ms, end_ms, "SelectSeries", step=1)
    seen = {int(p["timestamp"]) // 1000 for s in data.get("series", []) for p in s.get("points", []) if float(p.get("value", 0)) > 0}
    return sorted({t + d for t in seen for d in (-1, 0, 1)})


def stacks(base, kind, run, start_ms, end_ms):
    graph = query(base, kind, run, start_ms, end_ms, "SelectMergeStacktraces").get("flamegraph")
    if not graph:
        return {}
    return folded({"names": graph["names"], "levels": [[int(v) for v in lv.get("values", [])] for lv in graph["levels"]]})


def folded(fb):
    # flamebearer 의 층마다 [x 의 차, 합, 자기 몫, 이름] 이 넷씩 놓인다. 자식은 부모의 x 구간 안에 있다
    names, spans, out = fb["names"], [], {}
    for depth, level in enumerate(fb["levels"]):
        row, x = [], 0
        for i in range(0, len(level), 4):
            x += level[i]
            total, own, name = level[i + 1], level[i + 2], level[i + 3]
            if depth == 0:
                path = []
            else:
                parent = next(p for p in spans[depth - 1] if p[0] <= x < p[1] or p[0] == x == p[1])
                path = parent[2] + [names[name]]
            row.append((x, x + total, path))
            if own and path:
                key = ";".join(path)
                out[key] = out.get(key, 0) + own
            x += total
        spans.append(row)
    return out


def to_samples(stacks, rate):
    period = 1e9 / rate
    return {k: round(v / period) for k, v in stacks.items() if round(v / period) > 0}


def settled_total(base, kind, run, start_ms, end_ms, rate, wait=15, tries=8):
    # 회차가 막 끝나면 마지막 묶음이 아직 보이지 않을 수 있다. 회차 전체의 합이 두 번 연달아 같아질 때까지 기다린다
    last = None
    for _ in range(tries):
        now = sum(to_samples(stacks(base, kind, run, start_ms, end_ms), rate).values())
        if now == last:
            return now
        last = now
        time.sleep(wait)
    return last


def export(args):
    files, manifest = {}, {"run": args.run, "from": args.from_ms, "to": args.to_ms, "kinds": {}}
    for kind, (_, rate) in KINDS.items():
        whole = settled_total(args.pyroscope, kind, args.run, args.from_ms, args.to_ms, rate)
        batches, total = [], 0
        for t in candidate_seconds(args.pyroscope, kind, args.run, args.from_ms, args.to_ms):
            batch = to_samples(stacks(args.pyroscope, kind, args.run, t * 1000 - 1, t * 1000 + 1), rate)
            if not batch:
                continue
            files[f"{kind}/{t}.folded"] = "".join(f"{k} {v}\n" for k, v in sorted(batch.items())).encode()
            n = sum(batch.values())
            batches.append({"at": t, "samples": n})
            total += n
        # 묶음의 합이 회차 전체를 한 번에 물은 합과 같아야 빠진 묶음이 없다. 반올림 탓의 작은 차이는 남는다
        manifest["kinds"][kind] = {"sample_rate": rate, "batches": batches, "samples": total, "whole_samples": whole}
        print(f"profile {kind} {len(batches)} 묶음 {total} 표본 (회차 전체 {whole})")
    if not files:
        print("profile 이 회차의 프로파일이 없다. 프로파일링을 붙이지 않은 회차면 그대로 둔다")
        return 2
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, data in [("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=1).encode())] + sorted(files.items()):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    with open(args.out, "wb") as f:
        f.write(buf.getvalue())
    print(f"profile {args.out} {len(buf.getvalue())} 바이트")
    return 0


def restore(args):
    with tarfile.open(args.archive) as tar:
        manifest = json.load(tar.extractfile("manifest.json"))
        run = manifest["run"]
        for kind, meta in manifest["kinds"].items():
            for b in meta["batches"]:
                data = tar.extractfile(f"{kind}/{b['at']}.folded").read()
                q = urllib.parse.urlencode({"name": f"{SERVICE}.{kind}{{run={run}}}", "from": b["at"], "until": b["at"] + 10,
                                            "format": "folded", "sampleRate": meta["sample_rate"], "spyName": "javaspy",
                                            "units": "samples", "aggregationType": "sum"})
                request(args.pyroscope, "/ingest?" + q, data)
            print(f"restore {run} {kind} {len(meta['batches'])} 묶음 {meta['samples']} 표본")
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export")
    e.add_argument("--pyroscope", required=True)
    e.add_argument("--run", required=True)
    e.add_argument("--from", dest="from_ms", type=int, required=True)
    e.add_argument("--to", dest="to_ms", type=int, required=True)
    e.add_argument("--out", required=True)
    r = sub.add_parser("restore")
    r.add_argument("--pyroscope", required=True)
    r.add_argument("--archive", required=True)
    args = p.parse_args()
    sys.exit(export(args) if args.cmd == "export" else restore(args))


if __name__ == "__main__":
    main()

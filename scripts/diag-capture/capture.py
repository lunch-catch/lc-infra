"""
진단 회차의 병목 화면을 Grafana 에서 찍는다(lc-infra #106).

렌더러는 URL 을 열어 찍기만 하고 누르지 못한다. Call Tree 는 Drilldown 에서 눌러야 나오고 그 상태가 URL 에 남지 않아
브라우저 자동화로 찍는다. 트레이스 화면은 URL 로 열리지만 같은 브라우저로 함께 찍는다.

    python capture.py --grafana http://localhost:13000 --password <admin 비밀번호> --run <회차> --from <ms> --to <ms> \
        --out <폴더> [--trace <트레이스 ID> ...] [--expand <함수> ...]
"""
import argparse
import base64
import io
import json
import re
import urllib.parse
from pathlib import Path

from PIL import Image
from playwright.sync_api import sync_playwright

VIEWPORT = {"width": 1600, "height": 1200}
"""
Call Tree 를 사람이 병목을 찾듯 펼치는 기준이다(작성자가 2026-11-09 대화에서 정했다).
모두 측정에서 나온 값이 아니라 시작값이다. 실제 회차의 그림으로 확인한 뒤 고친다.
"""
# 자식의 Total 이 부모 Total 의 이 비율 이상이면 큰 갈래로 보고 펼친다. 고치면 부모가 눈에 띄게 빨라지는 갈래다
BRANCH_SHARE = 0.20
# 자식의 Total 이 기준을 넘은 진입점 Total 의 이 비율 이상일 때만 펼친다. 부모에 대한 비율만 보면 아주 작은 갈래 안에서도
# 계속 성립해 라이브러리 안쪽까지 수십 단계를 내려간다. 진입점 시간의 20분의 1 아래는 고쳐도 진입점이 거의 빨라지지 않는다
ENTRY_FLOOR_SHARE = 0.05
# 그 줄의 Self 가 자기 Total 의 이 비율 이상이면 그 함수를 병목으로 보고 더 내려가지 않는다
STOP_SELF_SHARE = 0.50

PROFILES = {
    "wall": "wall:wall:nanoseconds:cpu:nanoseconds",
    "cpu": "process_cpu:cpu:nanoseconds:cpu:nanoseconds",
}
# Call Tree 의 표는 보이는 높이만큼의 줄만 그린다(가상 목록). 높이 제한을 풀어도 나머지 줄은 그려지지 않는다.
# 그래서 표를 한 화면씩 내리며 찍어 한 장으로 잇는다. 표를 담은 상자에 표시를 달아 찾는다
MARK_TABLE = """() => {
  const boxes = Array.from(document.querySelectorAll('div')).filter(e => e.clientHeight > 200 && e.scrollHeight > e.clientHeight + 20);
  boxes.sort((a, b) => b.scrollHeight - a.scrollHeight);
  if (!boxes.length) return null;
  boxes[0].setAttribute('data-capture', 'table');
  boxes[0].scrollTop = 0;
  return [boxes[0].scrollHeight, boxes[0].clientHeight];
}"""
PERCENTS = re.compile(r"(\d+(?:\.\d+)?)%")


def main():
    args = parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    auth = "Basic " + base64.b64encode(f"admin:{args.password}".encode()).decode()
    with sync_playwright() as p:
        # 컨테이너 안의 localhost 는 호스트가 아니다. Grafana 의 root_url 이 localhost 라 페이지가 그 주소로 파일을 받으므로 호스트로 돌린다
        browser = p.chromium.launch(args=["--host-resolver-rules=MAP localhost host.docker.internal"])
        # 로캘을 주지 않으면 컨테이너 기본값이라 Grafana 가 Intl.NumberFormat 에서 멈춘다
        page = browser.new_page(viewport=dict(VIEWPORT), locale="ko-KR", timezone_id="Asia/Seoul",
                                extra_http_headers={"Authorization": auth})
        for kind, metric in PROFILES.items():
            path = out / f"diag-{args.run}-calltree-{kind}.png"
            capture_call_tree(page, args.grafana, args.run, args.frm, args.to, metric, args.expand, path)
            print(f"{path.name}")
        for n, trace_id in enumerate(args.trace, start=1):
            path = out / f"diag-{args.run}-trace-{n}.png"
            capture_trace(page, args.grafana, trace_id, args.frm, args.to, path)
            print(f"{path.name}  {trace_id}")
        browser.close()


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--grafana", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--run", required=True, help="프로파일의 run 라벨")
    parser.add_argument("--from", dest="frm", required=True, help="유닉스 밀리초")
    parser.add_argument("--to", required=True, help="유닉스 밀리초")
    parser.add_argument("--out", required=True)
    parser.add_argument("--trace", action="append", default=[])
    # 기준을 넘은 API 의 컨트롤러 메서드와 작업 메서드다. 판정(lc-backend #1128)이 넘긴다. 주지 않으면 맨 위 줄만 보인다
    parser.add_argument("--expand", action="append", default=[])
    return parser.parse_args()


def capture_call_tree(page, grafana, run, frm, to, metric, expand, path):
    page.set_viewport_size(dict(VIEWPORT))
    query = {"explorationType": "flame-graph", "var-dataSource": "pyroscope", "var-serviceName": "lunchcatch",
             "var-profileMetricId": metric, "from": frm, "to": to, "var-filters": f"run|=|{run}"}
    page.goto(f"{grafana}/a/grafana-pyroscope-app/explore?{urllib.parse.urlencode(query)}",
              wait_until="networkidle", timeout=60000)
    # 라디오 입력이 글자 위를 덮어 글자를 누르면 막힌다. 입력을 직접 누른다
    page.locator("input[id^=option-single]").first.click(force=True)
    page.locator("input[id^=option-callTree]").first.click(force=True)
    page.wait_for_load_state("networkidle")
    hide_menu(page)
    for name in expand:
        expand_hot_branches(page, name)
    page.evaluate("window.scrollTo(0, 0)")
    if expand:
        stitch_rows(page, path, expand)
    else:
        stitch_table(page, path)


def expand_hot_branches(page, name):
    """
    기준을 넘은 함수의 줄에서 시작해 사람이 병목을 찾는 순서로 펼친다(작성자가 2026-11-09 대화에서 정했다).
    - 자식 가운데 부모 Total 의 BRANCH_SHARE 이상인 것을 모두 펼친다. 가장 큰 자식 하나만 따라가면 둘째로 큰 갈래가 접힌다
    - 그 자식의 Total 이 진입점 Total 의 ENTRY_FLOOR_SHARE 이상일 때만 펼친다
    - 그 줄의 Self 가 자기 Total 의 STOP_SELF_SHARE 이상이면 더 내려가지 않는다. 시간 대부분이 그 함수 몸에서 나온다
    줄의 함수 이름을 누르면 한 단계 펼쳐지고, 자식이 하나뿐인 사슬은 Grafana 가 이어서 펼친다.
    """
    _, texts = read_rows(page)
    start = next((i for i, text in enumerate(texts) if function_name(text) == name), None)
    if start is None:
        print(f"  {name} 줄이 없다. 그 회차에 그 함수의 표본이 없다", flush=True)
        return
    expand_node(page, start, shares(texts[start])[1] * ENTRY_FLOOR_SHARE)


# 한 줄을 펼치고 큰 갈래의 자식을 차례로 펼친다. 앞의 줄은 펼쳐도 뒤로만 줄이 늘어 그 줄의 자리는 그대로다
def expand_node(page, index, floor):
    rows, texts = read_rows(page)
    self_share, total = shares(texts[index])
    if total == 0 or self_share / total >= STOP_SELF_SHARE:
        return
    if has_children(texts[index]) and not is_expanded(texts, index):
        click_name(rows[index], texts[index])
    ordinal = 0
    while True:
        _, texts = read_rows(page)
        hot = [i for i in direct_children(texts, index)
               if shares(texts[i])[1] >= max(total * BRANCH_SHARE, floor)]
        if ordinal >= len(hot):
            return
        expand_node(page, hot[ordinal], floor)
        ordinal += 1


# 줄마다 브라우저를 오가면 줄이 수백 개일 때 한 단계에 몇 초씩 걸린다. 글자는 한 번에 읽는다
def read_rows(page):
    texts = page.evaluate("() => Array.from(document.querySelectorAll('[role=row]')).slice(1).map(r => r.innerText.replace(/\\n/g, ' '))")
    rows = page.locator("[role=row]")
    return [rows.nth(i + 1) for i in range(len(texts))], texts


def function_name(text):
    parts = text.lstrip(" \t│├└─").split()
    return parts[0] if parts else ""


def has_children(text):
    return "child" in text


# 줄 끝의 두 비율이 Self 와 Total 이다. 둘 다 프로파일 전체에 대한 비율이다
def shares(text):
    found = [float(value) for value in PERCENTS.findall(text)]
    return (found[-2], found[-1]) if len(found) >= 2 else (0.0, 0.0)


# 바로 아래 줄이 더 깊으면 펼쳐진 줄이다
def is_expanded(texts, index):
    return index + 1 < len(texts) and depth(texts[index + 1]) > depth(texts[index])


# 그 줄 바로 아래 단계의 줄들이다. 그 줄보다 깊은 줄이 이어지는 동안 가장 얕은 깊이의 줄을 고른다
def direct_children(texts, index):
    base = depth(texts[index])
    below = []
    for i in range(index + 1, len(texts)):
        if depth(texts[i]) <= base:
            break
        below.append(i)
    if not below:
        return []
    nearest = min(depth(texts[i]) for i in below)
    return [i for i in below if depth(texts[i]) == nearest]


# 칸이 버튼을 덮어 보통으로 누르면 막힌다. 함수 이름을 단 버튼을 직접 누른다
def click_name(row, text):
    row.get_by_role("button", name=function_name(text), exact=True).first.click(force=True)
    row.page.wait_for_timeout(300)


# 함수 이름 앞의 나무 기호와 빈칸의 길이가 줄의 깊이다
def depth(text):
    return len(text) - len(text.lstrip(" \t│├└─"))


# 왼쪽 메뉴가 화면의 한쪽을 차지한다. 닫아 표가 넓어지게 한다(작성자가 2026-11-09 대화에서 정했다)
def hide_menu(page):
    close = page.get_by_role("button", name="Close menu")
    if close.count():
        close.first.click()
        page.wait_for_timeout(500)


# 그려진 줄마다 표 안에서의 위치, 높이, 글자를 읽는다. 위치는 내린 만큼을 더해 표 맨 위에서 잰다
ROW_SPANS = """e => {
  const top = e.getBoundingClientRect().top;
  return Array.from(document.querySelectorAll('[role=row]')).slice(1).map(r => {
    const box = r.getBoundingClientRect();
    return [Math.round(box.top - top + e.scrollTop), Math.round(box.height), r.innerText.replace(/\\n/g, ' ')];
  });
}"""


def stitch_rows(page, path, expand):
    """
    펼친 표에서 볼 줄만 골라 한 장으로 잇는다(작성자가 2026-11-09 대화에서 정했다).
    큰 갈래를 펼치면 Grafana 는 그 아래 자식을 모두 보여 주어, 0.01% 짜리 형제 줄이 그림의 절반을 넘는다.
    그래서 맨 위 total 줄과, 펼친 진입점 안에서 진입점 Total 의 ENTRY_FLOOR_SHARE 이상인 줄만 남긴다.
    표가 스크롤할 때 줄을 다시 그려 화면에서 숨길 수 없으므로, 표를 한 화면씩 내리며 찍은 그림에서 줄을 오려 잇는다.
    """
    sizes = page.evaluate(MARK_TABLE)
    if not sizes:
        page.screenshot(path=str(path), full_page=True)
        return
    bottom = page.locator("[data-capture=table]").bounding_box()
    page.set_viewport_size({"width": VIEWPORT["width"], "height": int(bottom["y"] + bottom["height"]) + 40})
    page.evaluate("window.scrollTo(0, 0)")
    page.evaluate(MARK_TABLE)
    page.wait_for_timeout(500)
    table = page.locator("[data-capture=table]")
    box = table.bounding_box()
    first = Image.open(io.BytesIO(page.screenshot(full_page=True)))
    rows, scrolled = {}, 0
    while True:
        shot = Image.open(io.BytesIO(page.screenshot(clip=box)))
        scale = shot.height / box["height"]
        for top, height, text in table.evaluate(ROW_SPANS):
            shown = top - scrolled
            if top not in rows and shown >= 0 and shown + height <= box["height"]:
                rows[top] = (text, shot.crop((0, int(shown * scale), shot.width, int((shown + height) * scale))))
        visible, total = table.evaluate("e => [e.clientHeight, e.scrollHeight]")
        if scrolled + visible >= total:
            break
        # 화면 끝에 걸쳐 잘린 줄을 다음 화면에서 온전히 찍도록 한 줄 높이만큼 덜 내린다
        scrolled += max(visible - 40, 20)
        # 표 끝에서는 브라우저가 내릴 수 있는 만큼만 내린다. 실제로 내린 위치를 읽어 줄의 자리를 잰다
        scrolled = table.evaluate("(e, y) => { e.scrollTop = y; return e.scrollTop; }", scrolled)
        page.wait_for_timeout(300)
    ordered = [rows[top] for top in sorted(rows)]
    kept = kept_rows([text for text, _ in ordered], expand)
    first_top = int(box["y"] + min(rows) if rows else box["y"])
    pieces = [first.crop((0, 0, first.width, first_top))] + [ordered[i][1] for i in kept]
    canvas = Image.new("RGB", (first.width, sum(piece.height for piece in pieces)), (17, 18, 23))
    y = 0
    for index, piece in enumerate(pieces):
        canvas.paste(piece, (0 if index == 0 else int(box["x"]), y))
        y += piece.height
    canvas.save(path)
    print(f"  {len(ordered) - len(kept)} 줄을 뺐다(진입점 Total 의 {ENTRY_FLOOR_SHARE:.0%} 미만이거나 진입점 바깥)", flush=True)


# 맨 위 total 줄과, 펼친 진입점마다 그 진입점 안에서 진입점 Total 의 ENTRY_FLOOR_SHARE 이상인 줄의 순번이다
def kept_rows(texts, expand):
    kept = {0}
    for start, text in enumerate(texts):
        if function_name(text) not in expand:
            continue
        floor = shares(text)[1] * ENTRY_FLOOR_SHARE
        kept.add(start)
        for i in range(start + 1, len(texts)):
            if depth(texts[i]) <= depth(text):
                break
            if shares(texts[i])[1] >= floor:
                kept.add(i)
    return sorted(kept)


def stitch_table(page, path):
    """
    페이지 위쪽(그래프와 표의 첫 화면)을 찍고, 표를 한 화면씩 내려 그 상자만 찍어 아래에 잇는다.
    마지막 화면은 앞 화면과 겹치는 만큼 잘라 같은 줄이 두 번 나오지 않게 한다.
    """
    sizes = page.evaluate(MARK_TABLE)
    if sizes:
        # 표가 창 아래로 넘치면 그 부분은 찍히지 않고 검게 나온다. 창을 표 아래까지 늘린다
        bottom = page.locator("[data-capture=table]").bounding_box()
        page.set_viewport_size({"width": VIEWPORT["width"], "height": int(bottom["y"] + bottom["height"]) + 40})
        page.evaluate("window.scrollTo(0, 0)")
        sizes = page.evaluate(MARK_TABLE)
    page.wait_for_timeout(500)
    first = Image.open(io.BytesIO(page.screenshot(full_page=True)))
    if not sizes:
        first.save(path)
        return
    total, visible = sizes
    table = page.locator("[data-capture=table]")
    box = table.bounding_box()
    top = int(box["y"] + box["height"])
    pieces = [first.crop((0, 0, first.width, top))]
    scrolled = 0
    # 트레이스의 스팬 목록은 내려가며 줄을 그릴 때마다 상자가 길어진다. 높이를 단계마다 다시 읽는다
    while scrolled + visible < (total := table.evaluate("e => e.scrollHeight")):
        step = min(visible, total - visible - scrolled)
        scrolled += step
        table.evaluate("(e, y) => { e.scrollTop = y; }", scrolled)
        page.wait_for_timeout(300)
        shot = Image.open(io.BytesIO(page.screenshot(clip=box)))
        pieces.append(shot.crop((0, shot.height - step, shot.width, shot.height)).resize((int(box["width"]), step)) if shot.width != int(box["width"]) else shot.crop((0, shot.height - step, shot.width, shot.height)))
    height = sum(piece.height for piece in pieces)
    canvas = Image.new("RGB", (first.width, height), (17, 18, 23))
    y = 0
    for index, piece in enumerate(pieces):
        canvas.paste(piece, (0 if index == 0 else int(box["x"]), y))
        y += piece.height
    canvas.save(path)


def capture_trace(page, grafana, trace_id, frm, to, path):
    page.set_viewport_size(dict(VIEWPORT))
    panes = {"a": {"datasource": "tempo", "queries": [{"refId": "A", "datasource": {"type": "tempo", "uid": "tempo"},
                                                         "queryType": "traceql", "query": trace_id}],
                   "range": {"from": frm, "to": to}}}
    page.goto(f"{grafana}/explore?schemaVersion=1&orgId=1&panes={urllib.parse.quote(json.dumps(panes))}",
              wait_until="networkidle", timeout=60000)
    page.wait_for_timeout(1500)
    hide_menu(page)
    page.get_by_test_id("data-testid explore-toolbar-content-outline-button").click()
    page.evaluate(HIDE_ABOVE_TRACE)
    # 임계 경로는 끝나는 시각을 실제로 늦춘 스팬의 사슬이다. 사람이 처음 보는 자리라 강조한다. 다른 스팬은 숨기지 않는다
    page.get_by_text("Critical path", exact=True).click()
    page.wait_for_timeout(500)
    open_slowest_critical_leaf(page)
    stitch_table(page, path)


"""
쿼리 편집기와 노드 그래프는 트레이스 위에서 한 화면의 절반을 차지한다. 트레이스 패널만 남기고 숨긴다.
쿼리 편집기는 트레이스 패널과 함께 담은 가장 가까운 상자를 찾아, 그 아래에서 트레이스 패널을 담지 않은 것을 숨긴다.
노드 그래프는 트레이스 패널을 담지 않는 가장 큰 바깥 상자까지 올라가 숨긴다.
"""
HIDE_ABOVE_TRACE = """() => {
  const trace = document.querySelector('[data-testid="data-testid Panel header Trace"]');
  const query = document.querySelector('[data-testid="query-editor-rows"]');
  if (!trace || !query) return;
  let common = query;
  while (!common.contains(trace)) common = common.parentElement;
  for (const child of common.children) if (!child.contains(trace)) child.style.display = 'none';
  let graph = document.querySelector('[data-testid="data-testid Panel header Node graph"]');
  while (graph && graph.parentElement && !graph.parentElement.contains(trace)) graph = graph.parentElement;
  if (graph && !graph.contains(trace)) graph.style.display = 'none';
}"""
# 그려진 스팬 줄마다 키, 이름 칸의 글자, 자식이 있는지, 임계 경로에 드는지를 읽는다
SPAN_ROWS = """() => Array.from(document.querySelectorAll('[data-item-key$="--bar"]')).map(r => {
  const name = r.querySelector('button[title]');
  return [r.getAttribute('data-item-key'), name ? name.innerText.replace(/\\n/g, ' ') : '',
          !!r.querySelector('[data-testid="icon-arrow-down"], [data-testid="icon-arrow-right"]'),
          !!r.querySelector('[data-testid="SpanBar--criticalPath"]')];
})"""
DURATION = re.compile(r"\(([\d.]+)(μs|ms|s)\)\s*$")
UNIT_MS = {"μs": 0.001, "ms": 1.0, "s": 1000.0}


def open_slowest_critical_leaf(page):
    """
    임계 경로에서 자식이 없는 스팬 가운데 가장 오래 걸린 것을 펼쳐 속성(쿼리문, 키 등)이 보이게 한다(작성자가 2026-11-09 대화에서 정했다).
    자식이 있는 스팬은 그 시간이 자식에게서 나오므로 실제로 일한 끝 스팬을 고른다.
    스팬 줄도 보이는 만큼만 그려지므로 상자를 한 화면씩 내리며 모든 줄을 읽는다.
    """
    sizes = page.evaluate(MARK_TABLE)
    if not sizes:
        return
    total, visible = sizes
    box = page.locator("[data-capture=table]")
    spans, scrolled = {}, 0
    while True:
        for key, name, has_children, critical in page.evaluate(SPAN_ROWS):
            match = DURATION.search(name)
            if critical and not has_children and match:
                spans[key] = float(match.group(1)) * UNIT_MS[match.group(2)]
        if scrolled + visible >= (total := box.evaluate("e => e.scrollHeight")):
            break
        scrolled += visible
        box.evaluate("(e, y) => { e.scrollTop = y; }", scrolled)
        page.wait_for_timeout(300)
    if not spans:
        return
    slowest = max(spans, key=spans.get)
    for y in range(0, total, visible):
        box.evaluate("(e, y) => { e.scrollTop = y; }", y)
        page.wait_for_timeout(300)
        row = page.locator(f'[data-item-key="{slowest}"] button[title]')
        if row.count():
            row.first.click(force=True)
            page.wait_for_timeout(500)
            return


if __name__ == "__main__":
    main()

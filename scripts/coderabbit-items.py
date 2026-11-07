#!/usr/bin/env python3
#
# .coderabbit.yaml 의 경로별 항목 목록을 가이드 원문에서 만든다 (lc-infra #102).
#
# 템플릿의 {{번호,번호}} 자리를 "근거 [문서](링크)" 와 항목 원문 목록으로 바꾼다.
# 원문을 손으로 옮기면 가이드를 고칠 때 어긋나므로 매번 이 스크립트로 다시 만든다.
#
#   python3 scripts/coderabbit-items.py docs/infra-review/coderabbit-template.yaml <lc-backend 작업 사본> > .coderabbit.yaml
#
import re
import sys
from pathlib import Path

INFRA = Path(__file__).resolve().parent.parent
TEMPLATE, BACKEND = Path(sys.argv[1]), Path(sys.argv[2])

INF_DOC = INFRA / "docs/infra-review/code-guideline.md"
INF_LINK = "https://github.com/lunch-catch/lc-infra/blob/main/docs/infra-review/code-guideline.md"
QA_DIR = BACKEND / "docs/software-quality"
QA_LINK = "https://github.com/lunch-catch/lc-backend/blob/main/docs/software-quality/"

# 번호 -> (문서 이름, 링크, 원문, 층위)
items = {}
for line in INF_DOC.read_text().splitlines():
    m = re.match(r"^\* `(INF-\d+-\d+)` (.+)$", line)
    if m:
        items[m.group(1)] = ("code-guideline.md", INF_LINK, m.group(2).strip(), "")
for f in sorted(QA_DIR.glob("qa-*-guideline.md")):
    for line in f.read_text().splitlines():
        m = re.match(r"^\* `\[([^]]+)\]` `([A-Z]+-\d+-\d+)` (.+)$", line)
        if m:
            items[m.group(2)] = (f.name, QA_LINK + f.name, m.group(3).strip(), m.group(1))


def block(ids, indent):
    groups = {}
    for i in ids:
        if i not in items:
            sys.exit(f"가이드에 없는 번호다: {i}")
        name, link, text, layer = items[i]
        if layer and layer != "인프라":
            sys.exit(f"{i} 는 [{layer}] 다. 이 저장소는 [인프라] 만 연다")
        groups.setdefault((name, link), []).append(f"- `{i}` {text}")
    out = []
    for (name, link), lines in groups.items():
        out += [f"근거 [{name}]({link})", ""] + lines + [""]
    return "\n".join((indent + l) if l else "" for l in out).rstrip()


def expand(m):
    indent = m.group(1)
    return block([x.strip() for x in m.group(2).split(",")], indent)


sys.stdout.write(re.sub(r"^( *)\{\{([^}]+)\}\}$", expand, TEMPLATE.read_text(), flags=re.M))

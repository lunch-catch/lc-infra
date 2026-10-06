#!/usr/bin/env bash
#
# G-LOCAL 진입점. 본체는 common 저장소에 있고 이 파일은 그것을 찾아 부른다.
#
# 본체를 여기 두지 않는 이유는 세 저장소가 같은 절차를 써야 하기 때문이다.
# 복사하면 갈라진다.
#
#   ./verify.sh                      전체. 아직 push 하지 않은 커밋 전부
#   ./verify.sh HEAD                 HEAD 커밋 하나
#   ./verify.sh <SHA>                그 커밋 하나
#   ./verify.sh -n 5                 최신 5개
#   ./verify.sh --agent claude       지시문을 그 명령에 넘긴다
#   ./verify.sh --help               나머지 사용법

set -u

# common 은 이름으로 찾지 않는다. 조직명도 저장소명도 clone 디렉터리 이름도 바뀐다.
# items.yml 첫머리의 source 필드가 그 저장소가 어느 갈래인지 스스로 말한다.
#
# 글롭 대신 find 를 쓰는 이유가 둘이다.
#   common 저장소의 기본 clone 이름이 .github 라 숨김 디렉터리가 되는데 ../*/ 가 건너뛴다.
#   ../.*/ 를 더하면 zsh 에서 매칭이 없을 때 no matches found 로 죽는다.
# 파이프 대신 프로세스 치환을 쓰는 이유는, 파이프로 while 을 돌리면 서브셸이라
# COMMON 이 바깥으로 전달되지 않기 때문이다.
COMMON=""
while IFS= read -r f; do
    if [ "$(sed -n 's/^source: *//p' "$f" | head -1)" = "common" ]; then
        COMMON=$(cd "$(dirname "$f")/../.." && pwd)
    fi
done < <(find .. -maxdepth 4 -path '*/.github/llm-verify/items.yml' 2>/dev/null)

: "${COMMON:=$HOME/.cache/llm-verify/common}"

if [ ! -x "$COMMON/.github/llm-verify/verify.sh" ]; then
    echo "common 저장소를 찾지 못했다: $COMMON" >&2
    echo >&2
    echo "옆에 clone 하거나 아래처럼 받는다." >&2
    echo "  ORG=\$(git remote get-url origin | sed -E 's#.*[/:]([^/]+)/[^/]+\$#\\1#')" >&2
    echo "  git clone --depth 1 \"https://github.com/\$ORG/.github.git\" ~/.cache/llm-verify/common" >&2
    exit 2
fi

exec "$COMMON/.github/llm-verify/verify.sh" --target "$(cd "$(dirname "$0")" && pwd)" "$@"

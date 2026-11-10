# 검증 실행 방법

## 로컬 검증

문서를 고치고 커밋한 뒤 저장소 루트에서 돌린다.

```
/v-commit
```

Claude CLI 모드에서 친다. 다른 CLI 를 쓰면 터미널에서 넘긴다.

```bash
./verify.sh --agent claude
./verify.sh --agent "gemini -p"
```

**`./verify.sh` 만 치면 지시문만 내고 판정은 하지 않는다.**

### 범위 바꾸기

| 인자 | 범위 |
|---|---|
| 없음 | 아직 push 하지 않은 커밋 전부 |
| `HEAD` | HEAD 커밋 하나 |
| `HEAD~1` | 그 앞 커밋 하나. git 이 읽는 그대로다 |
| `<SHA>` | 그 커밋 하나 |
| `-n 5` | 최신 5개 |

**ref 는 언제나 git 이 읽는 그대로다.** 개수는 `-n` 이 맡는다.

### 항목 범위 넓히기

```
/v-commit --full
```

```bash
./verify.sh --full
```

`--full` 은 커밋이 아니라 **점검 항목**을 넓힌다. 기본은 infra 항목만 보고,
`--full` 이면 common 의 품질 속성 항목까지 본다.

## PR 때는 CodeRabbit 이 리뷰하고, 막는 것은 결정론적 검사뿐이다

CodeRabbit 이 리뷰한다(lc-infra #102). fresh-market 의 LLM 판정(G-PR)을 대신한다.
**자동으로 돌지 않아** PR 을 연 뒤 `@coderabbitai review` 를 댓글로 달아 부르고, 지적마다 답글을 단다. 저장소 별이 10개 미만이라 CodeRabbit 이 자동 리뷰를 건너뛴다. 순서는 [인프라 변경 플로우](../workflow/인프라_변경_플로우.md) 4절이다.
이슈 등록부터 병합과 적용까지의 순서는 [인프라 변경 플로우](../workflow/인프라_변경_플로우.md)가 갖는다.
기준과 설정은 `docs/infra-review/INFRAREVIEW.md` 의 "PR 리뷰" 가 설명한다. **CodeRabbit 은 병합을 막지 않는다.** 재현율을 재지 않은 판정이라 지적만 남긴다.

병합을 막는 것은 CI 의 **결정론적인 검사**뿐이다.

| 워크플로 | 언제 | 차단 |
|---|---|---|
| `registry-check.yml` | 모든 PR | **막는다**. 필수 검사 `레지스트리 게이트` |
| `terraform.yml` | 모든 PR. Terraform 파일(`.tf`, `.tftpl`, 잠금 파일)을 안 건드렸으면 검사를 건너뛴다 | **막는다** (`fmt`, `validate`). 필수 검사 `인프라 코드 게이트` |
| `pr-gate.yml` | 모든 PR. 본문을 고치면 다시 돈다 | **막는다**. 본문에 `Closes #N` 이나 `Refs #N` 이 없으면 실패. 필수 검사 `이슈 게이트` |
| `wiki-sync.yml` | `main` 에 `docs/wiki/**` 가 바뀌면 | 안 막는다 |

**`main` 은 보호되어 있다**(lc-infra #129). PR 을 거쳐야 들어가고, 위 세 게이트가 통과하고 승인 1명이 있어야 병합된다. 관리자는 승인 없이 병합할 수 있다(`gh pr merge --admin`). 인프라를 주로 한 사람이 다루기 때문이다.

두 워크플로에 경로 필터를 두지 않는 이유가 있다. 필수 검사에 경로 필터가 걸리면 대상 파일을 안 바꾼 PR 은 검사 결과가 영영 오지 않아 병합하지 못한다. 그래서 늘 돌고, 할 일이 없으면 게이트가 바로 통과한다.

`terraform plan` 은 AWS 자격증명이 있을 때만 돈다. 없으면 건너뛰고 `fmt` 와 `validate` 만으로 판정한다.

**커버리지와 정적 분석 게이트는 없다.** 그 둘은 `lc-backend` 가 맡는다. 여기에는 테스트할 애플리케이션 코드가 없다.

## 점검 항목을 고쳤을 때

`items.yml` 은 `docs/infra-review/*-guideline.md` 에서 생성된 파생물이다. **문서를 고쳤으면 다시 생성한다.**

```bash
python3 ../common/.github/llm-verify/gen_items.py \
        docs/infra-review '*-guideline.md' infra 코드 \
        -o .github/llm-verify/items.yml
```

`--check` 를 주면 파일을 쓰지 않고 어긋났는지만 본다.

```
OK  infra 98건. 문서와 레지스트리가 일치한다
```

잊어도 `registry-check.yml` 이 잡지만, 그때는 PR 이 막힌다.

항목 문장을 고쳤으면 CodeRabbit 설정도 다시 만든다. 그쪽은 검사가 잡아 주지 않는다.

```bash
python3 scripts/coderabbit-items.py docs/infra-review/coderabbit-template.yaml ../lc-backend > .coderabbit.yaml
```

**항목 줄 아래 들여쓴 줄은 판정 기준으로 함께 실린다.**

```markdown
점검 항목
* `INF-3-02` JDBC URL에 `connectTimeout`과 `socketTimeout`이 있는가
  없으면 외부가 느려질 때 우리 스레드가 묶인다.
```

## 안 될 때

| 증상 | 조치 |
|---|---|
| 기준 저장소를 받겠다고 묻는다 | 처음 한 번만 묻는다. 승인한다 |
| 종료 코드 `2` | 기준 저장소를 못 찾았다. 화면의 안내대로 받는다 |
| "판정할 항목 없음" | 정상이다. 판정 대상 파일이 안 바뀌었을 때 그렇다 |
| 활성 항목이 적고 규칙이 `on_no_match` | 정상이다. 어떤 앵커에도 안 걸린 변경이다 |
| PR 에서 아무것도 안 돈다 | `registry-check` 는 문서를 건드린 PR 에서만 돈다 |

## 관련 문서

* PR 리뷰 기준과 설정: [INFRAREVIEW.md](../infra-review/INFRAREVIEW.md) 의 "PR 리뷰", 저장소 루트의 `.coderabbit.yaml`
* 일반 품질 속성: `lc-backend` 의 `docs/software-quality/`
* backend 쪽 리뷰 규약: `lc-backend` 의 `docs/CODEREVIEW.md`

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

## PR 때는 LLM 판정이 돌지 않는다

이 저장소의 CI 는 **결정론적인 검사만** 하고, 그것만 병합을 막는다.

| 워크플로 | 언제 | 차단 |
|---|---|---|
| `registry-check.yml` | 점검 항목 문서나 `items.yml` 을 건드린 PR | **막는다** |
| `terraform.yml` | `.tf` 를 건드린 PR | **막는다** (`fmt`, `validate`) |
| `wiki-sync.yml` | `main` 에 `docs/wiki/**` 가 바뀌면 | 안 막는다 |

`terraform plan` 은 AWS 자격증명이 있을 때만 돈다. 없으면 건너뛰고 `fmt` 와 `validate` 만으로 판정한다.

**커버리지와 정적 분석 게이트는 없다.** 그 둘과 LLM 판정(G-PR)은 `lc-backend` 가 맡는다. 여기에는 테스트할 애플리케이션 코드가 없다.

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

* 판정 절차: common 저장소의 `docs/verification/g-local.md`
* 설계 근거: common 저장소의 `docs/software-quality/qa-llm-verification.md`
* backend 쪽 검증: `lc-backend` 의 `docs/verification/verification-guide.md`

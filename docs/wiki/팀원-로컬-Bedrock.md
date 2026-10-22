# 팀원 로컬 Bedrock

로컬 백엔드는 기본으로 템플릿 생성의 가짜 구현을 쓴다. 진짜 모델로 프롬프트를 빠르게 고쳐 보려면 개발 팀 역할(`lunchcatch-dev-team`)로 Bedrock 을 부른다. 키를 나눠 주지 않는다.

| 항목 | 값 |
|---|---|
| 먼저 할 것 | [팀원 개발서버 접근](팀원-개발서버-접근.md) 1절의 준비. `lunchcatch-dev` 프로필이 있어야 한다 |
| 모델 | 서버와 같은 `jp.anthropic.claude-sonnet-4-6`, 도쿄(`ap-northeast-1`). 이 모델 하나만 부를 수 있다 |
| 자격 증명 | 역할의 임시 자격 증명. 최대 4시간 |
| 비용 | 템플릿 한 건에 약 0.04 USD |

설계와 이유는 `docs/system-design/런치캐치_LLM_Bedrock.md` 5.1절에 있다.

## 실행

백엔드에 AWS SDK 의 `sts` 모듈이 없어 `AWS_PROFILE=lunchcatch-dev` 만으로는 SDK 가 역할 프로필을 읽지 못한다. 임시 자격 증명을 환경변수로 넘긴다. 만료되면 첫 줄만 다시 실행한다.

```bash
# macOS
eval "$(aws configure export-credentials --profile lunchcatch-dev --format env)"
BEDROCK_MODEL_ID=jp.anthropic.claude-sonnet-4-6 BEDROCK_REGION=ap-northeast-1 ./gradlew bootRun
```

```powershell
# Windows
aws configure export-credentials --profile lunchcatch-dev --format powershell | Invoke-Expression
$env:BEDROCK_MODEL_ID="jp.anthropic.claude-sonnet-4-6"; $env:BEDROCK_REGION="ap-northeast-1"; ./gradlew bootRun
```

`BEDROCK_MODEL_ID` 가 있으면 가짜 구현 대신 실제 Bedrock 구현이 뜬다. `application-local.yml` 에 키를 넣지 않는다.

## 막히면

| 증상 | 할 일 |
|---|---|
| `not authorized to perform: bedrock:InvokeModel` | 모델 ID 나 리전이 위 값과 다르다. 이 역할은 그 모델 하나만 부를 수 있다 |
| `ExpiredToken` | 4시간이 지났다. 첫 줄을 다시 실행한다 |
| 가짜 응답이 온다 | `BEDROCK_MODEL_ID` 가 빠졌다 |

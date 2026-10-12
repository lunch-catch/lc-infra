# LLM 연동 (Amazon Bedrock)

작성 기준일: 2026-10-08
적용 대상: lc-backend 의 관리자 템플릿 생성과 수정 (#73, #95, "LLM 호출 Bedrock 교체" 이슈)
관련 문서: [런치캐치_개발서버.md](./런치캐치_개발서버.md), [백엔드공통_이미지저장소_설계.md](./백엔드공통_이미지저장소_설계.md)

관리자가 자연어로 요청하면 LLM 이 포스터 템플릿 HTML 을 만든다. 지금 백엔드는 고정 HTML 을 돌려주는 가짜 구현(`FakeTemplateHtmlGenerator`)을 쓴다. 이 문서는 그것을 Bedrock 호출로 바꿀 때 인프라가 무엇을 하고 무엇이 막혀 있는지를 적는다.

---

## 1. 무엇을 정했나

| 항목 | 결정 |
|---|---|
| 모델 | Anthropic Claude Sonnet 5 (2026-10-12. `gpt-6-sol` -> Claude Sonnet 5.5 -> `gpt-5.6-sol` -> `gpt-oss-120b` -> 이것) |
| 호출 ID | 모델 ID `anthropic.claude-sonnet-5` (추론 프로필 아님. 서울 리전 안에서 처리) |
| 호출 리전 | `ap-northeast-2` (서울). 변수 `bedrock_region` 으로 인프라 리전과 따로 둘 수 있다 (2.1절) |
| 환경 | 운영과 개발 둘 다 |
| 인증 | 서버 역할(인스턴스 프로필). 키를 앱에 넣지 않는다 |
| 경로 | 운영은 NAT, 개발은 퍼블릭 서브넷에서 바로. VPC 엔드포인트는 두지 않는다 (4절) |
| 나눔 | 인프라는 권한과 환경변수, 백엔드는 호출 코드 |
| 상태 | **아직 호출되지 않는다.** 계정 단위 제한과 Anthropic 사용 목적 신청서 두 가지가 남았다 (3절). 바로 쓸 수 있던 `gpt-oss-120b` 시험 기록은 2.3절에 남겼다 |

---

## 2. 모델과 비용

### 2.1 서울 리전 안에서 처리한다

Claude Sonnet 5 는 서울에서 모델 ID 로 바로 부를 수 있다(`ON_DEMAND`). 요청이 **서울 리전 안에서 처리된다.**

| 호출 ID | 처리 지역 | 단가 (입력 / 출력, 100만 토큰당 USD) |
|---|---|---|
| `anthropic.claude-sonnet-5` (택함) | 서울 | 2.2 / 11 |
| `global.anthropic.claude-sonnet-5` | AWS 가 고른 리전 | 2 / 10 |

10% 비싸지만 서울 안 처리를 택했다. 사용량이 작아 차이가 월 1 USD 안쪽이다(2.2절).

**리전 변수.** 모델이 서울에 없으면(예: `gpt-oss-120b` 는 도쿄에만 있었다) `bedrock_region` 을 그 리전으로 바꾼다.
새 리전을 처음 부를 때 `Your account is currently being verified` 로 2시간 안쪽 막힐 수 있다. 도쿄에서 실제로 그랬다.

### 2.2 비용

Marketplace 판매 조건(offer)의 값이다. 서울 리전 안 처리 기준 100만 토큰당 입력 2.2, 출력 11 USD 다.

템플릿 한 번에 입력 200, 출력 1,500 토큰이면 약 0.017 USD 다(출력 길이는 2.3절 `gpt-oss-120b` 시험값을 빌렸다). 월 300건이면 약 5 USD 다. 템플릿은 10개 상한이고(`POSTER-003`) 관리자만 만든다. 월 수백 건이어도 수 USD 다.

**청구는 Organization 관리 계정(497949018820)이 받는다.** 통합 결제라 이 계정의 비용이 그쪽 청구서로 간다. AWS 크레딧이 적용되는지는 크레딧 조건마다 달라 관리 계정에서 확인한다.

### 2.3 시험 결과 (2026-10-12, `gpt-oss-120b`)

Claude Sonnet 5 는 아직 호출되지 않아 재지 못했다. 바로 앞에 쓰던 도쿄 `gpt-oss-120b` 의 기록이다. 풀리면 같은 요청으로 다시 잰다.

관리자 템플릿과 같은 크기의 요청(포스터 HTML, 슬롯 5개)을 도쿄로 세 번 보냈다.

| 회차 | 응답 시간 | 출력 토큰 | 슬롯 | 스크립트 |
|---|---|---|---|---|
| 1 | 7.0초 | 1,349 | 5/5 | 없음 |
| 2 | 6.8초 | 1,376 | 5/5 | 없음 |
| 3 | 11.1초 | 2,099 | 5/5 | 없음 |

30초 상한(`POSTER-004`) 안에 들어온다. 응답은 출력 토큰 수에 비례해 늘어나므로 최대 출력 토큰을 정해 둔다(5절).

**모델에 따라 생각 과정 블록이 먼저 온다.** `gpt-oss-120b` 는 `content` 가 `reasoningContent` 다음 `text` 순서였다. 모델을 바꿔도 깨지지 않게 `text` 블록만 모은다.

---

## 3. 막혀 있는 것

Claude Sonnet 5 를 포함한 최신 모델이 계정 단위로 막혀 있다. 아래는 그것을 좁혀 간 기록이다.

### 3.1 증상

```
AccessDeniedException: openai.gpt-6-sol is not available for this account.
You can explore other available models on Amazon Bedrock.
For additional access options, contact AWS Sales ...
```

### 3.2 좁혀 간 순서 (2026-10-08)

| 확인 | 결과 | 판단 |
|---|---|---|
| Organization SCP | SCP 거부 문구(`explicit deny`)가 아니다 | SCP 아님 |
| 리전, 권한 (`get-foundation-model-availability`) | `regionAvailability` AVAILABLE, `authorizationStatus` AUTHORIZED | 정상 |
| 계정 플랜 (`freetier get-account-plan-state`) | `PAID` | Free 플랜 제한 아님 |
| Marketplace 계약 | 없었음 -> `create-foundation-model-agreement` 로 구독. 50초 뒤 AVAILABLE | 구독 완료 |
| 구독 후 호출 | 10분 동안 30초마다 시도. 계속 같은 거부 | 구독이 원인이 아니다 |
| 다른 최신 모델 | `gpt-6.1-sol`, `gpt-6-luna`, `gpt-5.5`, Claude Sonnet 5, Haiku 5.5 모두 같은 거부 | 모델 하나의 문제가 아니다 |
| 이전 모델 | Claude 3 Haiku, Nova Lite 는 응답한다 | Bedrock 경로 자체는 정상 |

**결론: 계정 단위로 최신 외부 모델이 막혀 있다.** 인프라 설정으로 풀 수 없다.

### 3.3 조치

AWS Support 에 케이스를 열었다 (2026-10-08, Account and billing, Service Account). 계정 ID, 리전, 모델, 오류 문구, 구독 상태, 용도를 적었다.

**풀리면 확인할 것.** 호출이 되는지, 그리고 템플릿 크기의 요청이 30초(`POSTER-004`) 안에 끝나는지 잰다.

```
aws bedrock-runtime converse --model-id global.openai.gpt-5.6-sol --region ap-northeast-2 \
  --messages '[{"role":"user","content":[{"text":"Reply with exactly: OK"}]}]'
```

**Claude 모델은 Anthropic 사용 목적 신청서도 따로 내야 한다.** 지금 이 계정은 내지 않은 상태다(`get-use-case-for-model-access` 가 ResourceNotFound). Claude 4.x 는 처음 몇 번 응답한 뒤 이 신청서를 요구하며 막혔다(2026-10-10). 계정 제한이 풀려도 이 신청서가 없으면 Sonnet 5.5 는 막힐 것으로 본다.

**계정 제한의 원인 후보.** Organization 관리 계정이 `sktpayer4@sktelecom.com` 이라 SK텔레콤이 결제를 맡는 구조로 보인다. 이런 계정은 Marketplace 를 거치는 외부 회사 모델이 막혀 있는 경우가 많다. 추론이며 이 계정 권한으로는 확인할 수 없다. Organization 운영 측에 묻는다.

---

## 4. 인프라 쪽 (반영함, 2026-10-08)

접근이 풀리기 전에 넣었다. 모델 ID 는 변수 `bedrock_model_id` 라 모델을 바꾸면 그 값만 고친다. 권한이 그 값을 따라 좁아진다.

### 4.1 권한

| 역할 | 어디 | 이유 |
|---|---|---|
| 운영 앱 서버 (`instance["app"]`) | `terraform/iam.tf` | 템플릿 API 는 앱 서버가 받는다 |
| 개발 서버 | `dev/main.tf` | 개발에서 먼저 시험한다 |
| 배치 서버 | 주지 않는다 | 배치는 LLM 을 부르지 않는다 |

허용 동작은 `bedrock:InvokeModel` 과 `bedrock:InvokeModelWithResponseStream` 이다. Converse API 도 이 둘로 판정된다.

**리소스는 모델 ARN 이다.** 추론 프로필(`global.`, `apac.` 등)로 부를 때는 프로필 ARN 도 함께 있어야 해서, 모델 ID 에 접두어가 있으면 그것을 더한다.

```
arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-5
arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-5
(추론 프로필일 때만) arn:aws:bedrock:<bedrock_region>:762794225116:inference-profile/<모델 ID>
```

`bedrock:*` 나 모든 모델로 넓히지 않는다. 앱 서버가 털리면 비싼 모델을 마음대로 부를 수 있다.

### 4.2 환경변수

| 이름 | 운영 | 개발 |
|---|---|---|
| `BEDROCK_MODEL_ID` | `anthropic.claude-sonnet-5` | 같음 |
| `BEDROCK_REGION` | `ap-northeast-2` | 같음 |

값은 `terraform/variables.tf`, `dev/variables.tf` 의 `bedrock_model_id` 와 `bedrock_region` 에서 오고 compose 템플릿이 넘긴다. 이름은 백엔드의 설정 키와 맞춘다. 백엔드가 다른 이름을 정하면 이쪽을 바꾼다.

### 4.3 네트워크

| 환경 | 경로 |
|---|---|
| 운영 | 프라이빗 서브넷 -> NAT -> `bedrock-runtime.ap-northeast-2.amazonaws.com` |
| 개발 | 퍼블릭 서브넷에서 바로 |

**VPC 엔드포인트를 두지 않는다.** 인터페이스 엔드포인트는 서울에서 AZ 하나에 월 약 10 USD 라 두 AZ 면 월 20 USD 남짓이다(데이터 처리료 별도). 관리자 템플릿 생성 몇 건을 위해 들일 값이 아니다. NAT 는 이미 있다.

### 4.4 개발 서버 반영

개발 서버는 user-data 변경을 무시한다 (개발 서버 문서 7장). 템플릿을 고치고, 떠 있는 서버의 compose 파일에도 같은 두 줄을 넣고 재시작했다. 권한은 역할 정책이라 apply 만으로 붙었다.

운영은 시작 템플릿에 들어갔다. 앱 서버는 다음 배포로 교체될 때 환경변수를 받는다. 권한은 이미 붙었다.

### 4.5 권한 확인

개발 서버의 역할로 직접 불러 보았다.

| 호출 | 결과 | 뜻 |
|---|---|---|
| `anthropic.claude-sonnet-5` | `not available for this account` | IAM 은 통과했고 3절의 계정 제한에서 멈췄다 (2026-10-12) |
| `anthropic.claude-opus-5` | `not authorized` | 같은 회사의 다른 모델도 IAM 이 막는다 |
| `apac.anthropic.claude-3-haiku...` | `not authorized to perform: bedrock:InvokeModel` | 정한 모델 밖은 IAM 이 막는다 |

---

## 5. 백엔드에 넘길 것

| 항목 | 값 |
|---|---|
| SDK | AWS SDK for Java v2 `bedrockruntime`. 이미 `software.amazon.awssdk:bom` 을 쓴다 |
| API | `Converse`. 모델마다 다른 요청 본문을 쓰지 않아도 된다 |
| 응답 읽기 | `content` 에서 `text` 블록만 모은다. 앞에 `reasoningContent` 블록이 온다 (2.3절) |
| 최대 출력 토큰 | 4,000 정도. 시험에서 2,100 까지 썼다. 너무 작으면 HTML 이 잘린다(`stopReason` 이 `max_tokens`) |
| 인증 | 기본 자격증명 체인. 서버에서는 인스턴스 프로필이 잡힌다. 키를 설정에 넣지 않는다 |
| 설정 | `BEDROCK_MODEL_ID`, `BEDROCK_REGION` |
| 시간 상한 | 30초 (`POSTER-004`). SDK 의 API 호출 타임아웃도 30초 안으로 건다 |
| 로컬 개발 | Bedrock 을 부르지 않는다. 지금의 가짜 구현을 로컬 프로필에서 계속 쓴다 |

---

## 6. 남은 일

| 할 일 | 누가 | 상태 |
|---|---|---|
| AWS Support 답변 받기. 케이스에 Claude Sonnet 5 를 덧붙인다 | 사람 | 대기 |
| Anthropic 사용 목적 신청서 제출 (Bedrock 콘솔) | 사람 | 대기 |
| 권한과 환경변수 넣기 (4절) | 인프라 | 완료 |
| 백엔드 호출 구현 | 백엔드 | 대기 |
| 풀린 뒤 Claude Sonnet 5 호출과 응답 시간 확인 | 인프라 | 대기 (`gpt-oss-120b` 는 완료, 2.3절) |

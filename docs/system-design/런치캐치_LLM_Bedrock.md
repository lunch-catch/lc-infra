# LLM 연동 (Amazon Bedrock)

작성 기준일: 2026-10-08
적용 대상: lc-backend 의 관리자 템플릿 생성과 수정 (#73, #95, "LLM 호출 Bedrock 교체" 이슈)
관련 문서: [런치캐치_개발서버.md](./런치캐치_개발서버.md), [백엔드공통_이미지저장소_설계.md](./백엔드공통_이미지저장소_설계.md)

관리자가 자연어로 요청하면 LLM 이 포스터 템플릿 HTML 을 만든다. 지금 백엔드는 고정 HTML 을 돌려주는 가짜 구현(`FakeTemplateHtmlGenerator`)을 쓴다. 이 문서는 그것을 Bedrock 호출로 바꿀 때 인프라가 무엇을 하고 무엇이 막혀 있는지를 적는다.

---

## 1. 무엇을 정했나

| 항목 | 결정 |
|---|---|
| 모델 | OpenAI `gpt-6-sol` |
| 호출 ID | 추론 프로필 `global.openai.gpt-6-sol` |
| 호출 리전 | `ap-northeast-2`. 처리는 AWS 가 고른 리전에서 될 수 있다 (2.1절) |
| 환경 | 운영과 개발 둘 다 |
| 인증 | 서버 역할(인스턴스 프로필). 키를 앱에 넣지 않는다 |
| 경로 | 운영은 NAT, 개발은 퍼블릭 서브넷에서 바로. VPC 엔드포인트는 두지 않는다 (4절) |
| 나눔 | 인프라는 권한과 환경변수, 백엔드는 호출 코드 |
| 상태 | **계정이 이 모델을 호출하지 못한다. AWS Support 케이스로 요청했다** (3절) |

---

## 2. 모델과 비용

### 2.1 추론 프로필을 쓰는 이유

`gpt-6-sol` 은 서울 리전에서 모델 ID 로 바로 부를 수 없고(`INFERENCE_PROFILE` 전용), 추론 프로필로만 부른다. 프로필이 가리키는 모델은 둘이다.

```
global.openai.gpt-6-sol
  -> arn:aws:bedrock:::foundation-model/openai.gpt-6-sol               (리전 없음, global)
  -> arn:aws:bedrock:ap-northeast-2::foundation-model/openai.gpt-6-sol
```

**`global.` 프로필은 요청을 한국 밖 리전에서 처리할 수 있다.** 템플릿 요청 문장에는 개인정보가 들어가지 않으므로 받아들인다. 개인정보가 들어가는 용도에 같은 프로필을 쓰려면 다시 판단한다.

### 2.2 비용

Marketplace 판매 조건(offer `offer-pycji3sz5gpcc`)의 값이다. 단위는 100만 토큰당 USD 로 읽었다.

| 항목 | 단가 (standard) |
|---|---|
| 입력 | 2 |
| 출력 | 10 |
| 캐시 읽기 | 0.2 |

템플릿 한 번에 입력 1천, 출력 2천 토큰이면 약 0.02 USD 다. 템플릿은 10개 상한이고(`POSTER-003`) 관리자만 만든다. 월 수백 건이어도 수 USD 다.

**청구는 Organization 관리 계정(497949018820)이 받는다.** 통합 결제라 이 계정의 비용이 그쪽 청구서로 간다. 외부 회사 모델이라 항목은 "AWS Marketplace" 로 따로 찍힌다. AWS 크레딧이 이 항목에 적용되는지는 크레딧 조건마다 달라 관리 계정에서 확인한다.

---

## 3. 지금 막혀 있는 것

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
aws bedrock-runtime converse --model-id global.openai.gpt-6-sol --region ap-northeast-2 \
  --messages '[{"role":"user","content":[{"text":"Reply with exactly: OK"}]}]'
```

**Claude 모델로 바꾸게 되면** Anthropic 사용 목적 신청서를 따로 내야 한다. 지금 이 계정은 내지 않은 상태다(`get-use-case-for-model-access` 가 ResourceNotFound).

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

**리소스는 셋 모두 적어야 한다.** 하나라도 빠지면 AccessDenied 다.

```
arn:aws:bedrock:ap-northeast-2:762794225116:inference-profile/global.openai.gpt-6-sol
arn:aws:bedrock:::foundation-model/openai.gpt-6-sol
arn:aws:bedrock:*::foundation-model/openai.gpt-6-sol
```

`bedrock:*` 나 모든 모델로 넓히지 않는다. 앱 서버가 털리면 비싼 모델을 마음대로 부를 수 있다.

### 4.2 환경변수

| 이름 | 운영 | 개발 |
|---|---|---|
| `BEDROCK_MODEL_ID` | `global.openai.gpt-6-sol` | 같음 |
| `BEDROCK_REGION` | `ap-northeast-2` | 같음 |

값은 `terraform/variables.tf`, `dev/variables.tf` 의 `bedrock_model_id` 와 `region` 에서 오고 compose 템플릿이 넘긴다. 이름은 백엔드의 설정 키와 맞춘다. 백엔드가 다른 이름을 정하면 이쪽을 바꾼다.

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
| `global.openai.gpt-6-sol` | `not available for this account` | IAM 은 통과했고 3절의 계정 제한에서 멈췄다 |
| `apac.anthropic.claude-3-haiku...` | `not authorized to perform: bedrock:InvokeModel` | 정한 모델 밖은 IAM 이 막는다 |

---

## 5. 백엔드에 넘길 것

| 항목 | 값 |
|---|---|
| SDK | AWS SDK for Java v2 `bedrockruntime`. 이미 `software.amazon.awssdk:bom` 을 쓴다 |
| API | `Converse`. 모델마다 다른 요청 본문을 쓰지 않아도 된다 |
| 인증 | 기본 자격증명 체인. 서버에서는 인스턴스 프로필이 잡힌다. 키를 설정에 넣지 않는다 |
| 설정 | `BEDROCK_MODEL_ID`, `BEDROCK_REGION` |
| 시간 상한 | 30초 (`POSTER-004`). SDK 의 API 호출 타임아웃도 30초 안으로 건다 |
| 로컬 개발 | Bedrock 을 부르지 않는다. 지금의 가짜 구현을 로컬 프로필에서 계속 쓴다 |

---

## 6. 남은 일

| 할 일 | 누가 | 상태 |
|---|---|---|
| AWS Support 답변 받기 | 사람 | 대기 |
| 권한과 환경변수 넣기 (4절) | 인프라 | 완료 |
| 백엔드 호출 구현 | 백엔드 | 대기 |
| 풀린 뒤 호출과 응답 시간 확인 (3.3절) | 인프라 | 대기 |

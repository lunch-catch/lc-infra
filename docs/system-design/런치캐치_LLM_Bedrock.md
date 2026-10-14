# LLM 연동 (Amazon Bedrock)

작성 기준일: 2026-10-08
적용 대상: lc-backend 의 관리자 템플릿 생성과 수정 (#73, #95, "LLM 호출 Bedrock 교체" 이슈)
관련 문서: [런치캐치_개발서버.md](./런치캐치_개발서버.md), [백엔드공통_이미지저장소_설계.md](./백엔드공통_이미지저장소_설계.md)

관리자가 자연어로 요청하면 LLM 이 포스터 템플릿 HTML 을 만든다. 지금 백엔드는 고정 HTML 을 돌려주는 가짜 구현(`FakeTemplateHtmlGenerator`)을 쓴다. 이 문서는 그것을 Bedrock 호출로 바꿀 때 인프라가 무엇을 하고 무엇이 막혀 있는지를 적는다.

---

## 1. 무엇을 정했나

| 항목 | 결정 |
|---|---|
| 모델 | OpenAI `gpt-oss-120b` (2026-10-12. 막힌 모델을 거쳐 지금 호출되는 것 중에서 골랐다. 후보 비교는 2.4절) |
| 호출 ID | 모델 ID `openai.gpt-oss-120b-1:0` (추론 프로필 아님) |
| 호출 리전 | **`ap-northeast-1` (도쿄).** 서울에 없다. 인프라 리전과 따로 둔다 (2.1절) |
| 환경 | 운영과 개발 둘 다 |
| 인증 | 서버 역할(인스턴스 프로필). 키를 앱에 넣지 않는다 |
| 경로 | 운영은 NAT, 개발은 퍼블릭 서브넷에서 바로. VPC 엔드포인트는 두지 않는다 (4절) |
| 나눔 | 인프라는 권한과 환경변수, 백엔드는 호출 코드 |
| 상태 | **호출된다.** 템플릿 한 건 7 ~ 11초, 슬롯 5개를 지킨다 (2.3절) |

---

## 2. 모델과 비용

### 2.1 도쿄에서 부르는 이유

`gpt-oss-120b` 는 서울(`ap-northeast-2`)에 없다. 2026-10-12 에 리전별로 확인했다.

| 리전 | `openai.gpt-oss-120b-1:0` |
|---|---|
| 서울 `ap-northeast-2` | 없음 |
| 도쿄 `ap-northeast-1` | **있음.** 가장 가깝다 |
| 싱가포르 `ap-southeast-1` | 없음 |
| 시드니, 뭄바이, 버지니아, 오리건, 프랑크푸르트 | 있음 |

추론 프로필이 없는 모델이라 모델 ID 로 리전을 지정해 부른다. 요청은 도쿄에서 처리된다.
**템플릿 요청 문장에는 개인정보가 들어가지 않으므로 받아들인다.** 개인정보가 들어가는 용도에 쓰려면 다시 판단한다.

인프라 리전(서울)과 따로 두려고 변수 `bedrock_region` 을 두었다. 모델을 서울에 있는 것으로 바꾸면 이 값도 함께 바꾼다.

**처음 도쿄를 부를 때 "계정 확인 중" 으로 한 번 막혔다.** `Your account is currently being verified. Verification normally takes less than 2 hours.`
새 리전을 처음 쓸 때 AWS 가 하는 확인이고, 2시간 안에 풀렸다. 그 뒤로 막히지 않는다.

### 2.2 비용

`gpt-oss-120b` 는 공개 가중치 모델이라 `gpt-6-sol`(100만 토큰당 입력 2, 출력 10 USD)보다 훨씬 싸다. 단가는 Bedrock 요금표에서 확인한다.

템플릿 한 번에 입력 200, 출력 1,300 ~ 2,100 토큰이었다(2.3절). 앞의 모델 단가로 쳐도 약 0.02 USD 다. 템플릿은 10개 상한이고(`POSTER-003`) 관리자만 만든다. 월 수백 건이어도 수 USD 다.

**청구는 Organization 관리 계정(497949018820)이 받는다.** 통합 결제라 이 계정의 비용이 그쪽 청구서로 간다. AWS 크레딧이 적용되는지는 크레딧 조건마다 달라 관리 계정에서 확인한다.

### 2.3 시험 결과 (2026-10-12)

관리자 템플릿과 같은 크기의 요청(포스터 HTML, 슬롯 5개)을 도쿄로 세 번 보냈다.

| 회차 | 응답 시간 | 출력 토큰 | 슬롯 | 스크립트 |
|---|---|---|---|---|
| 1 | 7.0초 | 1,349 | 5/5 | 없음 |
| 2 | 6.8초 | 1,376 | 5/5 | 없음 |
| 3 | 11.1초 | 2,099 | 5/5 | 없음 |

30초 상한(`POSTER-004`) 안에 들어온다. 응답은 출력 토큰 수에 비례해 늘어나므로 최대 출력 토큰을 정해 둔다(5절).

**응답에 생각 과정 블록이 먼저 온다.** `content` 가 `reasoningContent` 다음 `text` 순서다. 첫 블록을 HTML 로 읽으면 안 된다. `text` 블록만 모은다.

### 2.4 지금 호출되는 모델 비교 (2026-10-12)

계정 제한에 막히지 않은 모델만 비교했다. 같은 템플릿 요청을 두 번씩 보냈고, 단가는 AWS 요금 API 의 on-demand 값이다(100만 토큰당 USD).

| 모델 | 호출 리전, 처리 지역 | 응답 시간 | 출력 토큰 | 슬롯 | 단가 (입력/출력) | 월 300건 |
|---|---|---|---|---|---|---|
| Nova Micro `apac.amazon.nova-micro-v1:0` | 서울, 아시아태평양 | 약 2초 | 약 350 | 5/5 | 0.041 / 0.164 | 0.02 USD |
| Nova Lite `apac.amazon.nova-lite-v1:0` | 서울, 아시아태평양 | 약 2초 | 약 350 | 5/5 | 0.071 / 0.284 | 0.03 USD |
| Nova Pro `apac.amazon.nova-pro-v1:0` | 서울, 아시아태평양 | 약 2.7초 | 약 350 | 5/5 | 0.95 / 3.8 | 0.45 USD |
| Nova 2 Lite `global.amazon.nova-2-lite-v1:0` | 서울, 전 세계 | 약 2.9초 | 약 435 | 5/5 | 0.36 / 2.96 | 0.4 USD |
| gpt-oss-20b `openai.gpt-oss-20b-1:0` | 도쿄, 도쿄 | 10.5 ~ 15.6초 | 약 1,675 | 5/5 | 0.08 / 0.36 | 0.19 USD |
| **gpt-oss-120b** `openai.gpt-oss-120b-1:0` (택함) | 도쿄, 도쿄 | 4.5 ~ 6.2초 | 약 1,290 | 5/5 | 0.18 / 0.73 | 0.29 USD |

**서울 리전 안에서만 처리하는 모델은 지금 열린 것이 없다.** 서울에서 바로 부를 수 있는 텍스트 모델은 Claude 3 Haiku, Claude 3.5 Sonnet, Claude Sonnet 5, Opus 5 넷인데 모두 막혀 있다(3절).
서울 엔드포인트로 부를 수 있는 것은 Nova 넷이고, 이것도 처리는 아시아태평양이나 전 세계 리전에서 한다.

**gpt-oss-120b 를 고른 이유.** 생각 과정을 거쳐 출력이 길고 지시를 더 따진다. 디자인 품질을 우선했다.
비용은 어느 후보든 월 1 USD 를 넘지 않아 고르는 기준이 되지 않았다. 처리 지역을 서울 가까이 두려면 Nova Pro 가 대안이다.

---

## 3. 처음 고른 모델이 막힌 기록

`gpt-oss-120b` 로 바꾸기 전, 최신 모델들이 계정 단위로 막혀 있던 기록이다. 그 모델로 돌아갈 때 이 절을 본다.

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
arn:aws:bedrock:::foundation-model/openai.gpt-oss-120b-1:0
arn:aws:bedrock:*::foundation-model/openai.gpt-oss-120b-1:0
(추론 프로필일 때만) arn:aws:bedrock:<bedrock_region>:762794225116:inference-profile/<모델 ID>
```

`bedrock:*` 나 모든 모델로 넓히지 않는다. 앱 서버가 털리면 비싼 모델을 마음대로 부를 수 있다.

### 4.2 환경변수

| 이름 | 운영 | 개발 |
|---|---|---|
| `BEDROCK_MODEL_ID` | `openai.gpt-oss-120b-1:0` | 같음 |
| `BEDROCK_REGION` | `ap-northeast-1` | 같음 |

값은 `terraform/variables.tf`, `dev/variables.tf` 의 `bedrock_model_id` 와 `bedrock_region` 에서 오고 compose 템플릿이 넘긴다. 이름은 백엔드의 설정 키와 맞춘다. 백엔드가 다른 이름을 정하면 이쪽을 바꾼다.

### 4.3 네트워크

| 환경 | 경로 |
|---|---|
| 운영 | 프라이빗 서브넷 -> NAT -> `bedrock-runtime.ap-northeast-1.amazonaws.com` (도쿄) |
| 개발 | 퍼블릭 서브넷에서 바로 |

**VPC 엔드포인트를 두지 않는다.** 인터페이스 엔드포인트는 서울에서 AZ 하나에 월 약 10 USD 라 두 AZ 면 월 20 USD 남짓이다(데이터 처리료 별도). 관리자 템플릿 생성 몇 건을 위해 들일 값이 아니다. NAT 는 이미 있다.

### 4.4 개발 서버 반영

개발 서버는 user-data 변경을 무시한다 (개발 서버 문서 7장). 템플릿을 고치고, 떠 있는 서버의 compose 파일에도 같은 두 줄을 넣고 재시작했다. 권한은 역할 정책이라 apply 만으로 붙었다.

운영은 시작 템플릿에 들어갔다. 앱 서버는 다음 배포로 교체될 때 환경변수를 받는다. 권한은 이미 붙었다.

### 4.5 권한 확인

개발 서버의 역할로 직접 불러 보았다.

| 호출 | 결과 | 뜻 |
|---|---|---|
| `openai.gpt-oss-120b-1:0` (도쿄) | 응답함 | 정한 모델은 통과한다 (2026-10-12) |
| `openai.gpt-oss-20b-1:0` (도쿄) | `not authorized` | 같은 회사의 다른 모델도 IAM 이 막는다 |
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

### 5.1 로컬에서 직접 부를 때

로컬은 기본으로 가짜 구현을 쓰고, 진짜 호출은 개발 서버에서 확인한다. 로컬에서 진짜 모델을 불러야 할 때만 담당자 전용 키를 만든다 (`bootstrap/bedrock_local.tf` 의 `bedrock_local_users` 에 아이디를 넣고 apply).

| 항목 | 값 |
|---|---|
| IAM 사용자 | `lunchcatch-bedrock-local-<GitHub 아이디>`. 사람마다 따로 둔다. **지금은 없다** (2026-10-14 `yongmaru789` 용으로 만들었다가 담당자가 개발 서버에서 시험하기로 해 키와 사용자를 지웠다) |
| 권한 | `bedrock_local_model_id` 모델의 호출만. 콘솔 로그인, S3, SSM, 다른 모델은 막힌다 (2026-10-14 확인) |
| 키 발급 | Terraform 이 아니라 `aws iam create-access-key`. 상태 파일에 비밀 키를 남기지 않는다 |
| 전달 | 채팅, 이슈, 슬랙 평문으로 보내지 않는다 |
| 담당자 PC | `~/.aws/credentials` 의 `[lunchcatch-bedrock]` 프로필. 실행할 때 `AWS_PROFILE=lunchcatch-bedrock` 만 준다. `application-local.yml` 에 키를 넣지 않는다 |
| 정리 | 시험이 끝나면 `aws iam update-access-key --status Inactive` 로 끄거나 사용자를 지운다 |

**로컬 모델(Ollama 등)을 쓰지 않은 이유.** 지금 모델 `gpt-oss-120b` 는 메모리 65 GB 이상이 필요해 노트북에서 돌지 않는다.
`gpt-oss-20b` 는 돌지만 서버와 다른 모델이고, 노트북에서 템플릿 한 건이 30초 상한을 넘을 수 있으며, API 형식이 달라 로컬 전용 구현이 하나 더 생긴다.

**모델을 바꾸면 `bootstrap/` 의 `bedrock_local_model_id` 도 함께 바꾼다.** `terraform/` 과 루트가 달라 변수를 공유하지 못한다.

## 6. 남은 일

| 할 일 | 누가 | 상태 |
|---|---|---|
| AWS Support 답변 받기 (`gpt-6-sol` 등 최신 모델) | 사람 | 대기. 지금 모델에는 필요 없다 |
| 권한과 환경변수 넣기 (4절) | 인프라 | 완료 |
| 백엔드 호출 구현 | 백엔드 | 대기 |
| 호출과 응답 시간 확인 | 인프라 | 완료 (2.3절) |

# 작업 플로우

lc-infra 를 어떤 순서로 고치고, 어떤 게이트가 병합을 막고, 병합한 뒤 어떻게 적용하는지를 담는다.

이슈와 PR, 커밋, 문장의 규칙 자체는 이 폴더가 아니라 [저장소 규칙](../../CLAUDE.md)이 소유한다.

## 문서

| 문서 | 하는 일 |
|---|---|
| [인프라 변경 플로우](./인프라_변경_플로우.md) | 이슈를 등록하고 브랜치를 따서 PR 을 올리고, 게이트와 리뷰를 거쳐 병합한 뒤 환경에 적용하기까지 |

## 다른 곳에 있는 것

| 무엇 | 어디 |
|---|---|
| 리뷰 기준(INF- 항목, 품질 속성) | [docs/infra-review/INFRAREVIEW.md](../infra-review/INFRAREVIEW.md) |
| 검증 실행과 점검 항목 레지스트리 | [docs/verification/verification-guideline.md](../verification/verification-guideline.md) |
| 올리기, 배포, 롤백, 지우기 절차 | [docs/deploy/README.md](../deploy/README.md) |
| 팀원이 따라 하는 순서(부하 시험 환경 등) | [docs/wiki/](../wiki/) |

## 이 폴더에 문서를 더할 때

순서를 담은 문서면 위 표에 줄을 더한다. 이슈와 PR, 커밋, 문장 규칙은 여기에 적지 않고 `CLAUDE.md` 에 적는다.

# 실행 전 점검 가이드

이 문서는 배포와 시험을 **시작하기 전에 확인해야 하는 것**을 정리한다.

`code-guideline.md`와 판정 방식이 다르다. 파일을 읽어 판정하는 것이 아니라 **AWS API로 현재 상태를 조회해야** 알 수 있다.
따라서 LLM 리뷰가 아니라 **배포 스크립트와 시험 스크립트가 수행한다.** 이 문서는 그 스크립트의 사양이다.

출처: 무중단 배포 롤링 2.2절, 기술 스택 확정 문서 부록 A.9

## 1. 배포 사전 점검

배포는 아래를 확인한 뒤에만 시작한다. **하나라도 어긋나면 중단하고 원인을 먼저 해소한다.**

점검 항목
* `PRE-1-01` RDS가 `available`인가
  중지되었거나 유지보수 중이면 교체된 인스턴스가 기동에 실패한다.
* `PRE-1-02` ElastiCache가 `available`인가
  캐시 없이 배포하면 강등 경로가 섞여 판정이 흐려진다.
* `PRE-1-03` 모니터링 인스턴스가 `running`이고 Prometheus가 응답하는가
  관측 없이 배포하면 배포 영향을 판정할 수 없다.
* `PRE-1-04` 대상 그룹의 healthy 수가 desired와 일치하는가
  **가장 중요한 항목이다.** 이미 용량이 절반인 상태에서 롤링을 시작하면 서비스가 통째로 끊긴다.
* `PRE-1-05` ACM 인증서 잔여일이 30일을 넘는가
  배포 중 만료되면 전면 접속 불가가 된다.
* `PRE-1-06` Route 53 헬스체크가 정상인가
  외부에서 이미 접속 불가한 상태일 수 있다.

```bash
RDS_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text)
[ "$RDS_STATUS" = "available" ] || fail "RDS 상태가 $RDS_STATUS"

HEALTHY=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
DESIRED=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].DesiredCapacity' --output text)
[ "$HEALTHY" -ge "$DESIRED" ] || fail "대상 그룹 healthy $HEALTHY/$DESIRED"
```

## 2. 시험 사전 점검

부하 시험, 장애 주입, 복원 리허설 등 **운영과 동일한 구성에서 수행하는 모든 시험**에 적용한다.

배포 사전 점검과 목적이 다르다.

| 구분 | 배포 사전 점검 | 시험 사전 점검 |
|------|----------------|----------------|
| 막으려는 것 | 배포 실패 | **측정 결과 오염** |
| 판단 기준 | 절차가 성공할 수 있는가 | 결과를 신뢰할 수 있는가 |
| 크레딧 확인 | 없음 | 예정 시간만큼 있는가 |

점검 항목
* `PRE-2-01` 1절의 배포 사전 점검 항목을 모두 통과하는가
* `PRE-2-02` CPU 크레딧이 예정 시험 시간을 감당하는가
  부족한 상태로 부하를 걸면 측정값이 서버 성능이 아니라 **크레딧 소진 시점**이 된다.
* `PRE-2-03` Watchdog 신호가 최근 5분 내에 있는가
  알림 파이프라인이 끊긴 상태에서 시험하면 장애를 놓친다.
* `PRE-2-04` 직전 시험과 10분 이상 간격이 있는가
  CloudWatch 기본 모니터링이 5분 간격이라, 직후에는 마지막 데이터 포인트가 시험 전 값이어서 **실제보다 높은 잔량이 보인다.**
* `PRE-2-05` 배포가 진행 중이지 않은가
  인스턴스 수가 달라 조건이 바뀐다.

### 2.1 크레딧 게이트는 고정 임계를 쓰지 않는다

시험 유형마다 필요 시간이 다르고 인스턴스 구성도 바뀐다.
하나의 고정값으로는 짧은 시험이 불필요하게 막히거나 긴 시험이 도중에 마른다.

```
입력   13분, 목표 부하 100%
  ->
조회   현재 앱 인스턴스와 타입, RDS 인스턴스와 클래스
  ->
계산   대상별 필요 잔량과 현재 잔량
  ->
판정   가장 부족한 대상 기준으로 통과 또는 차단
```

점검 항목
* `PRE-2-06` 인스턴스 타입을 상수로 박지 않고 현재 구성을 조회해 계산하는가
  t3.small을 t3.medium으로 승급하면 vCPU와 적립량이 달라지는데, 상수로 두면 계산이 조용히 틀린다.
* `PRE-2-07` 계산에 RDS를 포함하는가
  RDS는 EC2보다 적립량이 절반이라 두 배 빨리 소진된다. 부하 시험 중에는 RDS 쪽을 먼저 본다.

## 3. 이 문서가 LLM 게이트 대상이 아닌 이유

세 가지가 겹친다.

| 이유 | 내용 |
|------|------|
| 판정에 런타임 조회가 필요하다 | 파일에 답이 없다. AWS API를 호출해야 한다 |
| 판정 시점이 PR이 아니다 | 배포 직전과 시험 직전이다 |
| 판정 결과가 이진이다 | 통과 또는 차단. LLM의 의미 판단이 필요 없다 |

**스크립트가 이 판정을 하고, LLM 게이트는 그 스크립트가 존재하고 절차에 묶여 있는지만 본다.**
후자는 `operation-guideline.md`가 다룬다.

## 4. 관련 문서

* 근거: `docs/system-design/백엔드공통_무중단배포_롤링.md` 2.2절, `백엔드공통_기술스택_확정문서.md` 부록 A.9
* PR 단위 점검: [code-guideline.md](./code-guideline.md)
* 도입 판정과 검증 계획: [operation-guideline.md](./operation-guideline.md)

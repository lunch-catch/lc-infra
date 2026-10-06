#!/usr/bin/env bash
#
# 세션 종료. 기술 스택 확정 문서 부록 A.4 절차를 그대로 옮겼다.
#
# 순서가 의존 방향에서 나온다. 의존하는 쪽(앱)부터 내린다.
# 앱보다 RDS 를 먼저 내리면 커넥션 오류가 마지막 구간의 지표를 오염시킨다.
#
# 중지로 줄일 수 있는 폭이 작다. ALB 와 ElastiCache 와 NAT 는 중지가 불가능하다.
# 게이트웨이는 켜고 끄는 물건이 아니라 있거나 없거나다.
#
#   ALB + ElastiCache   월 약 29 USD
#   NAT x2              월 약 86 USD   (2026-09-23 이중화)
#                       ───────────
#                       약 115 USD 가 중지해도 계속 나간다
#
# 상시 245~286 USD 대비 절반도 못 줄인다. **오래 안 쓸 거면 중지가 아니라 파괴가 맞다.**

set -euo pipefail

PROJECT="${PROJECT:-lunchcatch}"
REGION="${AWS_REGION:-ap-northeast-2}"

# 프로필을 빠뜨려도 default 자격증명(다른 계정)으로 가지 않게 한다.
# CI 는 OIDC 자격증명을 환경변수로 받으므로 프로필을 건드리지 않는다. 없는 프로필을 걸면 CLI 가 죽는다.
if [ -z "${AWS_PROFILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  export AWS_PROFILE=lunchcatch
fi
# 그래도 다른 계정을 가리키면 아무것도 하기 전에 멈춘다. terraform/versions.tf 의 allowed_account_ids 와 같은 장치다.
ACCOUNT_ID="${ACCOUNT_ID:-762794225116}"
current_account=$(aws sts get-caller-identity --query Account --output text)
if [ "$current_account" != "$ACCOUNT_ID" ]; then
  printf 'ERROR: 계정 %s 를 가리킨다. %s 여야 한다. AWS_PROFILE 을 확인한다\n' "$current_account" "$ACCOUNT_ID" >&2
  exit 1
fi

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# 0. 알람 알림을 먼저 끈다.
#
#    desired 0 은 HealthyHostCount 를 0 으로 만들고, 모니터링 중지는 StatusCheckFailed 를 올린다.
#    둘 다 critical 이라 세션을 끊을 때마다 장애가 아닌 알림이 두 번씩(발생과 복구) 간다.
#    오탐이 쌓이면 진짜 알람을 무시하게 되므로 여기서 막는다.
#
#    알람 자체는 지우지 않는다. 알림만 끄고 상태 기록은 계속 남긴다.
log "0. 알람 알림 중지"
aws cloudwatch disable-alarm-actions --region "$REGION" \
  --alarm-names "$PROJECT-healthy-host-count" "$PROJECT-monitoring-status" "$PROJECT-batch-capacity"

# 1. 앱을 먼저 내린다.
#    stop-instances 를 쓰면 ASG 가 비정상으로 보고 교체해 세션을 끝낼 수 없다 (INF-23).
#    min 을 함께 내려야 한다. min 1 인 채로 desired 0 을 주면 AWS 가 거절한다.
log "1. ASG min 0 / desired 0"
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$PROJECT-app" \
  --min-size 0 --desired-capacity 0 --region "$REGION"

# 2. 관측 데이터 내보내기는 사람이 판단한다.
#    모니터링 인스턴스는 stop 이라 EBS 가 남지만, 인스턴스를 잃을 상황에 대비한 안내다.
log "2. 관측 데이터를 남길 것이 있으면 지금 내보낸다 (건너뛰려면 Enter)"
if [ -t 0 ]; then read -r _; fi

# 3. 모니터링은 ASG 밖이라 stop 으로 다룬다.
#    desired 0 은 EBS 까지 지워 Prometheus 와 Loki 데이터가 사라진다 (INF-24).
mon_id=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$mon_id" != "None" ] && [ -n "$mon_id" ]; then
  log "3. 모니터링 인스턴스 중지 $mon_id"
  aws ec2 stop-instances --instance-ids "$mon_id" --region "$REGION" > /dev/null
else
  log "3. 모니터링 인스턴스가 이미 내려가 있다"
fi

# 배치도 ASG 라 앱과 같이 min 과 desired 를 0 으로 내린다. stop-instances 를 쓰면 ASG 가 교체한다.
# 스케줄러가 도는 채로 두면 DB 가 꺼진 뒤 계속 실패한다. 배치는 디스크에 상태가 없어 지워도 된다.
log "3. 배치 ASG min 0 / desired 0"
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$PROJECT-batch" \
  --min-size 0 --desired-capacity 0 --region "$REGION"

# 4. RDS 를 마지막에 내린다. 완료를 기다릴 필요는 없다.
#    최대 7일 뒤 자동으로 다시 시작되므로 주 1회 이상 재중지가 필요하다.
status=$(aws rds describe-db-instances --db-instance-identifier "$PROJECT-db" \
  --region "$REGION" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo missing)
if [ "$status" = "available" ]; then
  log "4. RDS 중지"
  aws rds stop-db-instance --db-instance-identifier "$PROJECT-db" --region "$REGION" > /dev/null
  log "   최대 7일 뒤 자동 시작된다. 그 전에 다시 내려야 한다"
else
  log "4. RDS 상태가 $status 라 건너뛴다"
fi

echo
log "중지 완료. ALB 와 ElastiCache 는 중지가 불가능해 계속 과금된다"

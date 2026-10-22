#!/usr/bin/env bash
#
# 기본 계정 비밀번호를 SSM 에 둔다 (lc-infra #29, lc-backend #741).
# 앱의 기본 세계(lc-backend db/base)가 이 해시로 superadmin, demo-admin, 시연 점주, 시나리오 계정을 넣는다.
#
#   ./account-passwords.sh /lunchcatch       운영. apply.sh 가 부른다
#   ./account-passwords.sh /lunchcatch/dev   개발. dev-up.sh 가 부른다
#
# 계정마다 두 값을 둔다.
#   <접두사>/account-<계정>-password        평문. 사람이 로그인에 쓴다. SecureString
#   <접두사>/account-<계정>-password-hash   BCrypt 해시. 서버가 .env 로 앱에 넘긴다. String
#
# 없을 때만 무작위로 만든다. 있는 값은 건드리지 않는다. 몇 번 돌려도 안전하다.
# 기본 세계는 이미 있는 계정을 건너뛰므로, 앱이 계정을 넣은 뒤 값을 바꾸면 DB 와 어긋난다. 바꾸려면 앱에서도 바꾼다.
set -euo pipefail

PREFIX="${1:?usage: $0 /lunchcatch|/lunchcatch/dev}"
REGION="${AWS_REGION:-ap-northeast-2}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "오류: $*"; exit 1; }

command -v htpasswd > /dev/null || die "htpasswd 가 없다. 해시를 만들 수 없다 (macOS 는 기본으로 있다)"

for account in superadmin demo-admin demo-owner scenario; do
  name="$PREFIX/account-$account-password"
  if aws ssm get-parameter --name "$name" --region "$REGION" > /dev/null 2>&1; then
    log "   $account 비밀번호 그대로"
    continue
  fi
  # 점주 로그인은 10 ~ 20자를 받는다. 16자로 만든다
  password="Lc-$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-12)!"
  # htpasswd 는 $2y$ 로 낸다. 알고리즘은 같고 앱의 기본값과 맞추려 $2a$ 로 바꾼다
  hash=$(htpasswd -nbBC 10 "" "$password" | tr -d ':\n' | sed 's/^\$2y\$/$2a$/')
  aws ssm put-parameter --name "$name-hash" --region "$REGION" --type String --overwrite \
    --value "$hash" --description "$account 비밀번호의 BCrypt 해시. 기본 세계가 넣는다" > /dev/null
  aws ssm put-parameter --name "$name" --region "$REGION" --type SecureString \
    --value "$password" --description "$account 로그인 비밀번호" > /dev/null
  log "   $account 비밀번호 만듦"
done

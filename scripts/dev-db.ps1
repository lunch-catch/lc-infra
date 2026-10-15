<#
 개발 서버 MySQL 에 내 컴퓨터의 포트로 붙는다 (docs/system-design/런치캐치_개발서버.md 10장). dev-db.sh 의 Windows 판이다.
 SSM 포트 포워딩이라 서버에 열린 포트가 없다. 이 창을 닫으면 연결이 끊긴다.

   .\scripts\dev-db.ps1                  localhost:13306 으로 연다
   .\scripts\dev-db.ps1 -LocalPort 3307

 필요한 것: AWS CLI, Session Manager 플러그인
   winget install -e --id Amazon.AWSCLI
   winget install -e --id Amazon.SessionManagerPlugin
 팀원 키는 lunchcatch-dev 프로필에 둔다. 다른 프로필이면 $env:AWS_PROFILE 로 넘긴다.
#>
param(
    [int]$LocalPort = 13306
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# aws CLI 가 한글을 UTF-8 로 내보내게 한다
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

if (-not $env:AWS_PROFILE -and -not $env:AWS_ACCESS_KEY_ID) { $env:AWS_PROFILE = "lunchcatch-dev" }
$Region = if ($env:AWS_REGION) { $env:AWS_REGION } else { "ap-northeast-2" }

# 설치 프로그램이 PATH 에 넣지 않는 경우가 있어 기본 설치 위치도 본다
$plugin = Get-Command session-manager-plugin -ErrorAction SilentlyContinue
$defaultPlugin = "C:\Program Files\Amazon\SessionManagerPlugin\bin\session-manager-plugin.exe"
if (-not $plugin) {
    if (-not (Test-Path $defaultPlugin)) {
        Write-Error "Session Manager 플러그인이 없다. winget install -e --id Amazon.SessionManagerPlugin 후 터미널을 다시 연다"
    }
    $env:Path += ";" + (Split-Path $defaultPlugin)
}

$instanceId = aws ec2 describe-instances --region $Region `
    --filters "Name=tag:Role,Values=dev-server" "Name=instance-state-name,Values=running" `
    --query "Reservations[0].Instances[0].InstanceId" --output text
if ($LASTEXITCODE -ne 0) {
    Write-Error "AWS 호출이 실패했다. lunchcatch-dev 프로필의 키를 확인한다"
}
if (-not $instanceId -or $instanceId -eq "None") {
    Write-Error "개발 서버가 꺼져 있다. 인프라 담당에게 켜 달라고 한다"
}

$password = aws ssm get-parameter --region $Region --name /lunchcatch/dev/team-db-password `
    --with-decryption --query Parameter.Value --output text
if ($LASTEXITCODE -ne 0) {
    Write-Error "DB 비밀번호를 읽지 못했다. 인프라 담당에게 묻는다"
}

Write-Host @"
개발 DB 에 연결한다. 이 창을 열어 둔 동안만 붙는다 (Ctrl+C 로 끊는다).

  Host      127.0.0.1
  Port      $LocalPort
  Database  lunchcatch
  User      team
  Password  $password

데이터는 읽고 쓸 수 있고 테이블 구조는 바꿀 수 없다. 팀원 모두가 쓰는 데이터라 지울 때 조심한다.
"@

aws ssm start-session --region $Region --target $instanceId `
    --document-name AWS-StartPortForwardingSession `
    --parameters "portNumber=3306,localPortNumber=$LocalPort"

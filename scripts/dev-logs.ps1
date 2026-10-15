<#
 개발 서버 앱 로그를 본다 (docs/system-design/런치캐치_개발서버.md 10장). dev-logs.sh 의 Windows 판이다.
 CloudWatch Logs /lunchcatch/dev/app 를 읽는다. 배포로 컨테이너가 바뀌어도 14일 남는다.

   .\scripts\dev-logs.ps1                       최근 10분부터 실시간으로 따라간다
   .\scripts\dev-logs.ps1 2h                    최근 2시간부터
   .\scripts\dev-logs.ps1 30m ERROR             최근 30분 중 ERROR 가 들어간 줄만 (따라가지 않는다)
   .\scripts\dev-logs.ps1 1h MEMBER_WITHDRAWAL

 팀원 키는 lunchcatch-dev 프로필에 둔다. 다른 프로필이면 $env:AWS_PROFILE 로 넘긴다.
#>
param(
    [string]$Since = "10m",
    [string]$Pattern = ""
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# aws CLI 가 한글을 UTF-8 로 내보내게 한다
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

if (-not $env:AWS_PROFILE -and -not $env:AWS_ACCESS_KEY_ID) { $env:AWS_PROFILE = "lunchcatch-dev" }
$Region = if ($env:AWS_REGION) { $env:AWS_REGION } else { "ap-northeast-2" }
$Group = "/lunchcatch/dev/app"

# 한 줄 JSON 을 "시각 레벨 메시지" 로 보여 준다. JSON 이 아니면 원문 그대로 둔다
function Format-LogLine([string]$line) {
    $message = $line -replace '^\S+\s', ''
    try {
        $j = $message | ConvertFrom-Json -ErrorAction Stop
        # PowerShell 7 은 시각 문자열을 날짜로 바꿔 읽는다
        $ts = $j.'@timestamp'
        $time = if ($ts -is [datetime]) { $ts.ToString("HH:mm:ss.fff") } else { ([string]$ts).Substring(11, 12) }
        $out = "$time $($j.level) $($j.message)"
        if ($j.stack_trace) { $out += "`n" + $j.stack_trace }
        return $out
    } catch {
        return $message
    }
}

$awsArgs = @("logs", "tail", $Group, "--region", $Region, "--since", $Since, "--format", "short")
if ($Pattern) { $awsArgs += @("--filter-pattern", $Pattern) } else { $awsArgs += "--follow" }

& aws @awsArgs | ForEach-Object { Format-LogLine $_ }

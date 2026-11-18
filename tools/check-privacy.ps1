# 提交前的隐私自检（PowerShell 版，与 tools/check-privacy.sh 等价）。
#
# 检查即将提交的内容里有没有不该进公开仓库的东西：
#   · 本机的绝对路径（Windows / macOS / Linux 的家目录）
#   · 邮箱、GitHub Token、私钥、疑似云厂商 Key
#   · 常见的证书 / 密钥文件
#
# 用法：
#   ./tools/check-privacy.ps1              # 检查暂存区（pre-commit 会调用）
#   ./tools/check-privacy.ps1 -Tree        # 检查 HEAD 里的全部文件
#
# 误报时用 $env:SKIP_PRIVACY_CHECK = '1' 跳过，但要想清楚。

[CmdletBinding()]
param([switch]$Tree)

$ErrorActionPreference = 'Stop'

if ($env:SKIP_PRIVACY_CHECK -eq '1') {
    Write-Host '隐私检查已跳过（SKIP_PRIVACY_CHECK=1）' -ForegroundColor Yellow
    exit 0
}

$root = git rev-parse --show-toplevel
if (-not $root) { throw '不在 git 仓库里' }
Set-Location $root

if ($Tree) {
    $files = git ls-files
} else {
    $files = git diff --cached --name-only --diff-filter=ACMR
}
if (-not $files) { exit 0 }

$badNamePattern = '(^|/)\.env$|(^|/)local\.properties$|\.(jks|keystore|p12|pfx|mobileprovision)$|(^|/)id_(rsa|ed25519|ecdsa)$'
$binaryExtensions = '\.(png|jpe?g|gif|webp|ico|icns|bmp|jar|so|dll|dylib|a|lib|exe|apk|aab|zip|gz|zst|7z|ttf|otf|woff2?|mp[34]|flac|wav|ogg|opus)$'

# 本机路径 + 凭据。宁可误报也不要漏。
$patterns = @(
    @{ Name = '本机绝对路径'; Regex = 'C:\\?\\?Users\\\\?|C:/Users/|/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/|\\\\Users\\\\[A-Za-z0-9._-]+\\\\' },
    @{ Name = '邮箱';         Regex = '[A-Za-z0-9._%+-]+@(gmail|qq|outlook|hotmail|163|126|foxmail)\.[A-Za-z]{2,}' },
    @{ Name = 'GitHub Token'; Regex = 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}' },
    @{ Name = '私钥';         Regex = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
    @{ Name = '疑似 API Key'; Regex = 'sk-[A-Za-z0-9]{24,}|AKIA[0-9A-Z]{16}' }
)

$fail = $false

$badNames = $files | Where-Object { $_ -match $badNamePattern }
if ($badNames) {
    Write-Host '✗ 疑似密钥或凭据文件：' -ForegroundColor Red
    $badNames | ForEach-Object { Write-Host "    $_" }
    $fail = $true
}

$textFiles = $files | Where-Object { $_ -notmatch $binaryExtensions }

foreach ($f in $textFiles) {
    if ($Tree) {
        $content = git show "HEAD:$f" 2>$null
    } else {
        $content = git show ":$f" 2>$null
    }
    if (-not $content) { continue }
    $lines = $content -split "`n"
    foreach ($p in $patterns) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $p.Regex) {
                Write-Host ("✗ {0}（{1}:{2}）：{3}" -f $p.Name, $f, ($i + 1), $lines[$i].Trim()) -ForegroundColor Red
                $fail = $true
            }
        }
    }
}

if ($fail) {
    Write-Host ''
    Write-Host '请修正后重试；确认是误报可以设置 SKIP_PRIVACY_CHECK=1 跳过。' -ForegroundColor Yellow
    exit 1
}

Write-Host '✓ 隐私检查通过' -ForegroundColor Green
exit 0

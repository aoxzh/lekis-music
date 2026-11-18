# 为 Windows 编译 Rust 核心，复制到 apps/windows/src/Lekis.Core.Interop/native/<rid>/lekis_ffi.dll
# 发布构建使用 MSVC 工具链（需要 Visual Studio Build Tools）；本机只有 GNU 工具链时可以传 -Target x86_64-pc-windows-gnu。
param(
    [string]$Target = 'x86_64-pc-windows-msvc',
    [string]$Profile = 'release'
)
$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$Rid = switch -Wildcard ($Target) {
    'x86_64-*' { 'win-x64' }
    'aarch64-*' { 'win-arm64' }
    default { throw "unknown target $Target" }
}

Push-Location (Join-Path $Root 'core')
try {
    cargo build --profile $Profile --target $Target -p lekis-ffi
    if ($LASTEXITCODE -ne 0) { throw 'cargo build failed' }
    $dir = if ($Profile -eq 'dev') { 'debug' } else { $Profile }
    $out = Join-Path $Root "apps\windows\src\Lekis.Core.Interop\native\$Rid"
    New-Item -ItemType Directory -Force $out | Out-Null
    Copy-Item "target\$Target\$dir\lekis_ffi.dll" $out -Force
    Write-Host "copied lekis_ffi.dll -> $out"
} finally {
    Pop-Location
}

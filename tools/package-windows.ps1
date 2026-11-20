# 把 Windows release 构建打成免安装 zip：dist/lekis-<版本>-windows-x64.zip（dist/ 不提交）。
#
#   tools/package-windows.ps1                  # flutter build windows --release，然后打包
#   tools/package-windows.ps1 -SkipBuild       # 只打包已有的 app/build/windows/x64/runner/Release
#   tools/package-windows.ps1 -Version 0.1.0-alpha.1
#
# 版本默认取 app/pubspec.yaml 的 version（去掉 +build）。release.yml 也用这个脚本。
#
# Flutter 程序和 lekis_bridge.dll 都动态链接 MSVC 运行库；默认把 msvcp140 / vcruntime140 /
# vcruntime140_1 一起放进 zip（微软允许随应用本地分发），没装 VC++ 运行库的机器也能直接打开。
# -NoVCRuntime 可以跳过。

param(
    [switch]$SkipBuild,
    [string]$Version = '',
    [string]$OutDir = '',
    [switch]$NoVCRuntime
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'app'
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

if (-not $Version) {
    $line = Select-String -Path (Join-Path $app 'pubspec.yaml') -Pattern '^version:\s*(\S+)' | Select-Object -First 1
    if (-not $line) { throw 'app/pubspec.yaml 里没有 version' }
    $Version = ($line.Matches[0].Groups[1].Value -split '\+')[0]
}

if (-not $SkipBuild) {
    # 优先用 PATH 上的 flutter（CI），否则用工具链目录（LEKIS_DEV_ROOT，默认 %USERPROFILE%\dev）。
    $flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
    if (-not $flutter) {
        $dev = if ($env:LEKIS_DEV_ROOT) { $env:LEKIS_DEV_ROOT } else { Join-Path $env:USERPROFILE 'dev' }
        $flutter = Join-Path $dev 'toolchains\flutter\bin\flutter.bat'
        if (-not (Test-Path $flutter)) { throw "找不到 flutter：PATH 上没有，$flutter 也不存在" }
    }
    Push-Location $app
    try {
        & $flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows 失败（退出码 $LASTEXITCODE）" }
    } finally {
        Pop-Location
    }
}

$release = Join-Path $app 'build\windows\x64\runner\Release'
foreach ($f in 'lekis.exe', 'lekis_bridge.dll', 'flutter_windows.dll', 'data') {
    if (-not (Test-Path (Join-Path $release $f))) { throw "release 目录不完整，缺少 $f：$release" }
}

$name = "lekis-$Version-windows-x64"
$staging = Join-Path $OutDir $name
$zip = Join-Path $OutDir "$name.zip"
New-Item -ItemType Directory -Force $OutDir | Out-Null
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
if (Test-Path $zip) { Remove-Item -Force $zip }

# zip 里多一层 lekis-<版本>-windows-x64\ 目录，解压时不会把文件撒一地。
Copy-Item -Recurse $release $staging
# 构建残留（调试符号、导入库）不进包。
Get-ChildItem $staging -Recurse -Include '*.pdb', '*.lib', '*.exp', '*.ilk' | Remove-Item -Force

if (-not $NoVCRuntime) {
    $sys = Join-Path $env:SystemRoot 'System32'
    foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
        $src = Join-Path $sys $dll
        if (Test-Path $src) {
            Copy-Item $src $staging -Force
        } else {
            Write-Warning "没找到 $src，zip 里不带它（目标机器需要装 VC++ 2015-2022 运行库）"
        }
    }
}

Compress-Archive -Path $staging -DestinationPath $zip -CompressionLevel Optimal
Remove-Item -Recurse -Force $staging

$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "打包完成：$zip（$size MB）"
Write-Host "SHA256  $hash"

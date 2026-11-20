# 把 Windows release 构建打成免安装 zip：dist/lekis-<版本>-windows-x64.zip 和同名 .sha256（dist/ 不提交）。
#
#   tools/package-windows.ps1                        # flutter build windows --release，然后打包
#   tools/package-windows.ps1 -SkipBuild             # 只打包已有的 app/build/windows/x64/runner/Release
#   tools/package-windows.ps1 -InDir <Release 目录>   # 打包另一份构建（默认就是上面那个 Release 目录）
#   tools/package-windows.ps1 -SkipZip               # 只整理出 staging 目录、不压缩（查漏文件用）
#   tools/package-windows.ps1 -Shortcut              # 顺便给 staging 目录建开始菜单快捷方式（保留 staging 不删）
#   tools/package-windows.ps1 -Version 0.1.0-alpha.1
#
# 版本默认取 app/pubspec.yaml 的 version 行，去掉 +build 后缀；-Version 优先。
# release.yml 用 -SkipBuild -Version $env:VERSION 调用这个脚本，参数名不要改。
#
# Release 目录整个复制进 zip：data/（Flutter assets、icudtl.dat）、native_assets.json、
# 插件 DLL（各 *_plugin.dll、cnativeapi.dll 等）都在里面，不要只挑固定文件。
#
# Flutter 程序和 lekis_bridge.dll 都动态链接 MSVC 运行库；默认把 msvcp140 / vcruntime140 /
# vcruntime140_1 一起放进 zip（微软允许随应用本地分发），没装 VC++ 运行库的机器也能直接打开。
# -NoVCRuntime 可以跳过。
# 脚本只打包 $InDir 这一个目录里的内容，所以 CI 上先 flutter build，再 -SkipBuild 打包。

param(
    [string]$InDir = '',
    [switch]$SkipBuild,
    [string]$Version = '',
    [string]$OutDir = '',
    [switch]$SkipZip,
    [switch]$NoVCRuntime,
    [switch]$Shortcut
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'app'
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
if (-not $InDir) { $InDir = Join-Path $app 'build\windows\x64\runner\Release' }
$InDir = [System.IO.Path]::GetFullPath($InDir, (Get-Location).Path)

if (-not $Version) {
    $line = Select-String -Path (Join-Path $app 'pubspec.yaml') -Pattern '^version:\s*(\S+)' | Select-Object -First 1
    if (-not $line) { throw 'app/pubspec.yaml 里没有 version' }
    # 0.1.0-alpha.1+build.7 → 0.1.0-alpha.1
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

foreach ($f in 'lekis.exe', 'lekis_bridge.dll', 'flutter_windows.dll', 'data') {
    if (-not (Test-Path (Join-Path $InDir $f))) { throw "release 目录不完整，缺少 $f：$InDir" }
}

$name = "lekis-$Version-windows-x64"
$staging = Join-Path $OutDir $name
$zip = Join-Path $OutDir "$name.zip"
$sha = Join-Path $OutDir "$name.zip.sha256"
New-Item -ItemType Directory -Force $OutDir | Out-Null
foreach ($stale in $staging, $zip, $sha) {
    if (Test-Path $stale) { Remove-Item -Recurse -Force $stale }
}

# zip 里多一层 lekis-<版本>-windows-x64\ 目录，解压时不会把文件撒一地。
Copy-Item -Recurse $InDir $staging
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

if ($Shortcut) {
    # 快捷方式指向 staging 目录（解压后就是用户直接运行的那份），所以 -Shortcut 时 staging 保留。
    & (Join-Path $PSScriptRoot 'install-windows-shortcut.ps1') -ExePath $staging
}

if ($SkipZip) {
    Write-Host "已整理到 $staging（-SkipZip：没有压缩，也没有算 SHA256）"
    return
}

Compress-Archive -Path $staging -DestinationPath $zip -CompressionLevel Optimal
if (-not $Shortcut) { Remove-Item -Recurse -Force $staging }

$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
# sha256sum 的格式（<哈希>␠␠<文件名>），Linux/macOS 上 shasum -a 256 -c 能直接校验。
Set-Content -Path $sha -Value "$hash  $name.zip" -Encoding ascii
Write-Host "打包完成：$zip（$size MB）"
Write-Host "SHA256  $hash"
Write-Host "校验值：$sha"
if ($Shortcut) { Write-Host "快捷方式指向保留的 staging 目录：$staging" }

# 日常联调：只为当前连接设备的 ABI 构建（Rust 核心也只编这一个架构）。
#
#   tools/dev-android.ps1                 # flutter run（debug，可热重载）
#   tools/dev-android.ps1 -Mode release   # 构建 release APK 并安装
#   tools/dev-android.ps1 -Device <adb 序列号>
#
# 不带 --target-platform 的 `flutter build apk` 会把 arm / arm64 / x64 三套
# Rust 核心全编一遍；这个脚本从设备读 ro.product.cpu.abi，只编一套。

param(
    [ValidateSet('run', 'debug', 'release')]
    [string]$Mode = 'run',
    [string]$Device = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
# 工具链根目录：LEKIS_DEV_ROOT，默认 %USERPROFILE%\dev。
$dev = if ($env:LEKIS_DEV_ROOT) { $env:LEKIS_DEV_ROOT } else { Join-Path $env:USERPROFILE 'dev' }

$env:JAVA_HOME = "$dev\toolchains\jdk17"
$env:ANDROID_HOME = "$dev\android-sdk"
$env:ANDROID_NDK_HOME = "$dev\android-sdk\ndk\27.2.12479018"
$env:CARGO_HOME = "$dev\cargo"
$env:RUSTUP_HOME = "$dev\rustup"
$env:PATH = "$dev\cargo\bin;$dev\android-sdk\platform-tools;$env:PATH"
$flutter = "$dev\toolchains\flutter\bin\flutter.bat"

if (-not $Device) {
    $Device = (adb devices | Select-String '\tdevice$' | Select-Object -First 1).Line -replace '\t.*', ''
    if (-not $Device) { throw '没有连接的 adb 设备' }
}

$abi = (adb -s $Device shell getprop ro.product.cpu.abi).Trim()
$platform = switch ($abi) {
    'arm64-v8a' { 'android-arm64' }
    'armeabi-v7a' { 'android-arm' }
    'x86_64' { 'android-x64' }
    default { throw "不支持的 ABI: $abi" }
}
Write-Host "设备 $Device  ABI $abi  →  $platform"

Set-Location "$root\app"
switch ($Mode) {
    'run' {
        & $flutter run -d $Device --target-platform $platform
    }
    default {
        & $flutter build apk "--$Mode" --target-platform $platform
        $apk = "build\app\outputs\flutter-apk\app-$Mode.apk"
        adb -s $Device install -r $apk
    }
}

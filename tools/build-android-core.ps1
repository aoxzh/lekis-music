<#
.SYNOPSIS
    为 Android 编译 Rust 核心（lekis-ffi → liblekis_ffi.so），输出到
    apps/android/core/bridge/src/main/jniLibs/<abi>/。

.DESCRIPTION
    PowerShell 版的 build-android-core.sh（那个仍然留给 Linux/CI 用）。
    做的事和 .sh 一样，外加 Windows 上必须的自动探测：

      1. 找到 NDK（见 -NdkHome / 环境变量 / ANDROID_HOME/ndk/* 里挑最高版本），
         并设好 ANDROID_NDK_HOME / ANDROID_NDK_ROOT / NDK_HOME —— cargo-ndk v4
         只认这几个变量，SDK 目录里有什么它自己不看；
      2. 检查 rustup target 和 cargo-ndk 是否就位，缺了直接报错而不是让 cargo 半路炸；
      3. 调 `cargo ndk -t <abis> --platform <api> -o <jniLibs> build --profile <profile> -p lekis-ffi`；
      4. 列出生成的 .so 和大小，并对每个 ABI 做 ELF 机器字自检（可选 -Verify），
         确认真的是 ARM64 / ARMv7 / x86_64 而不是误编成了宿主机架构。

.PARAMETER Profile
    cargo profile。release-android（core/Cargo.toml 里定义，inherits release + opt-level=s）
    用于交付；dev 用于快速验证链路。

.PARAMETER Abis
    要编的 ABI，默认和 Gradle 的 abiFilters 一致。

.PARAMETER Platform
    Android API level（默认 26，和 minSdk 一致）。

.PARAMETER NdkHome
    显式指定 NDK 根目录；不传就自动探测。

.EXAMPLE
    pwsh -File tools/build-android-core.ps1                    # release-android，三个 ABI
    pwsh -File tools/build-android-core.ps1 -Profile dev        # 快速验证
    pwsh -File tools/build-android-core.ps1 -Abis arm64-v8a     # 只编 64 位 ARM
#>
[CmdletBinding()]
param(
    [string]$Profile = 'release-android',
    [string[]]$Abis = @('arm64-v8a', 'armeabi-v7a', 'x86_64'),
    [int]$Platform = 26,
    [string]$NdkHome,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'

$Root      = Resolve-Path (Join-Path $PSScriptRoot '..')
$CoreDir   = Join-Path $Root 'core'
$JniLibs   = Join-Path $Root 'apps\android\core\bridge\src\main\jniLibs'
$LibName   = 'liblekis_ffi.so'

# --------------------------------------------------------------------------
# 0. 自带工具链环境
#     脚本要能在**全新、什么都没有的** shell 里直接跑（CI、刚开的
#     pwsh -NoProfile、右键 Run with PowerShell），所以自己补齐，
#     而不是要求调用者先 dot-source 什么。
# --------------------------------------------------------------------------
$envScript = Join-Path $PSScriptRoot 'env-windows-gnu.ps1'
if (Test-Path $envScript) {
    # 它会把 CARGO_HOME / RUSTUP_HOME 设好、把 $CARGO_HOME\bin 加到 PATH 前面、
    # 并设 LEKIS_LLVM_MINGW_DIR（后面做 dlltool 垫片要用）。它只在
    # RUSTUP_TOOLCHAIN 未设置时才写死 windows-gnu，所以下面换工具链不会被它覆盖。
    . $envScript
}
if (-not $env:CARGO_HOME) {
    $fallback = Join-Path $env:USERPROFILE 'dev\cargo'
    if (Test-Path $fallback) { $env:CARGO_HOME = $fallback }
}
if (-not $env:RUSTUP_HOME) {
    $fallback = Join-Path $env:USERPROFILE 'dev\rustup'
    if (Test-Path $fallback) { $env:RUSTUP_HOME = $fallback }
}
if ($env:CARGO_HOME) {
    $cargoBin = Join-Path $env:CARGO_HOME 'bin'
    if ((Test-Path $cargoBin) -and (($env:Path -split ';') -notcontains $cargoBin)) {
        $env:Path = "$cargoBin;$env:Path"
    }
}

# ABI → rustc target，用来查 rustup target list 和做 ELF 自检
$AbiToTarget = @{
    'arm64-v8a'   = 'aarch64-linux-android'
    'armeabi-v7a' = 'armv7-linux-androideabi'
    'x86_64'      = 'x86_64-linux-android'
}
$AbiToMachine = @{
    'arm64-v8a'   = 0xB7   # EM_AARCH64
    'armeabi-v7a' = 0x28   # EM_ARM
    'x86_64'      = 0x3E   # EM_X86_64
}

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# --------------------------------------------------------------------------
# 1. 找 NDK
# --------------------------------------------------------------------------
function Find-NdkHome {
    param([string]$Explicit)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Explicit) { $candidates.Add($Explicit) }

    # cargo-ndk v4 认的三个变量，按优先级
    foreach ($v in 'ANDROID_NDK_HOME', 'ANDROID_NDK_ROOT', 'NDK_HOME') {
        $val = [Environment]::GetEnvironmentVariable($v)
        if ($val) { $candidates.Add($val) }
    }

    # $ANDROID_HOME/ndk/<version>，取版本号最高的
    foreach ($sdkVar in 'ANDROID_HOME', 'ANDROID_SDK_ROOT') {
        $sdk = [Environment]::GetEnvironmentVariable($sdkVar)
        if (-not $sdk) { continue }
        $ndkRoot = Join-Path $sdk 'ndk'
        if (Test-Path $ndkRoot) {
            Get-ChildItem $ndkRoot -Directory |
                Sort-Object { try { [version]($_.Name -replace '[^0-9.].*$', '') } catch { [version]'0.0' } } -Descending |
                ForEach-Object { $candidates.Add($_.FullName) }
        }
    }

    # 默认 SDK 位置兜底
    foreach ($sdk in (Join-Path $env:LOCALAPPDATA 'Android\Sdk'), (Join-Path $env:USERPROFILE 'dev\android-sdk')) {
        $ndkRoot = Join-Path $sdk 'ndk'
        if (Test-Path $ndkRoot) {
            Get-ChildItem $ndkRoot -Directory | ForEach-Object { $candidates.Add($_.FullName) }
        }
    }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        # NDK 目录的特征：有这个 clang 包装脚本
        $probe = Join-Path $c 'toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android26-clang.cmd'
        $binDir = Join-Path $c 'toolchains\llvm\prebuilt\windows-x86_64\bin'
        if ((Test-Path $probe) -and (Test-Path $binDir)) { return (Resolve-Path $c).Path }
    }
    return $null
}

Write-Step '探测 Android NDK'
$Ndk = Find-NdkHome -Explicit $NdkHome
if (-not $Ndk) {
    throw @'
找不到 Android NDK。请任选一种方式指定：
  - 传 -NdkHome <NDK 根目录>
  - 设置 ANDROID_NDK_HOME=<NDK 根目录>
  - 设置 ANDROID_HOME=<SDK 根目录>（脚本会去 <SDK>\ndk\<version> 里挑）
需要的是含 toolchains\llvm\prebuilt\windows-x86_64\bin 的那一层，例如
  <Android SDK 目录>\ndk\27.2.12479018
'@
}
Write-Host "    NDK: $Ndk"

# cargo-ndk v4 只看环境变量，显式写回去（顺便保证子进程 cargo 也能看到）
$env:ANDROID_NDK_HOME = $Ndk
$env:ANDROID_NDK_ROOT = $Ndk
$env:NDK_HOME          = $Ndk
if (-not $env:ANDROID_HOME)     { $sdkGuess = Split-Path (Split-Path $Ndk -Parent) -Parent; $env:ANDROID_HOME = $sdkGuess }
if (-not $env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME }

# --------------------------------------------------------------------------
# 1.5 准备 dlltool 垫片（windows-gnu 宿主的坑，见文件末尾注释）
# --------------------------------------------------------------------------
function Ensure-DlltoolShim {
    <#
      宿主机是 x86_64-pc-windows-gnu 时，编译 Android 目标仍然要在宿主机上编
      build script 的依赖（例如 jni -> walkdir -> winapi-util -> windows-sys），
      而 windows-sys 需要生成 import library，会去调 `dlltool`。
      rustup 的 gnu 工具链 self-contained 环境里**没有** dlltool.exe，于是报
      `error calling dlltool 'dlltool.exe': program not found`。

      注意：给 rustc 传 `-Cdlltool=<llvm-dlltool 路径>` 只能修**目标单元**
      （RUSTFLAGS / CARGO_TARGET_*_RUSTFLAGS 都只作用于 target unit），
      对 host build script 的依赖无效，所以唯一稳的办法是把一个真的
      dlltool.exe 放进 PATH。

      llvm-mingw 的 llvm-dlltool.exe 不能直接改名复制走：它依赖同目录的
      libLLVM-23.dll 等，单独拷出来会以 -1073741515 (0xC0000135) 退出。
      所以复制成一个独立目录，并把必需的 DLL 一起放进去。
    #>
    $shim = Join-Path $env:USERPROFILE 'dev\toolchains\dlltool-shim'
    $shimExe = Join-Path $shim 'dlltool.exe'
    if (Test-Path $shimExe) {
        $env:PATH = "$shim;$env:PATH"
        return $shim
    }

    $mingwBin = $env:LEKIS_LLVM_MINGW_DIR
    if (-not $mingwBin -or -not (Test-Path (Join-Path $mingwBin 'llvm-dlltool.exe'))) {
        $cand = Get-ChildItem -Path (Join-Path $env:USERPROFILE 'dev\toolchains\llvm-mingw') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($cand) { $mingwBin = Join-Path $cand.FullName 'bin' }
    }
    if (-not $mingwBin -or -not (Test-Path (Join-Path $mingwBin 'llvm-dlltool.exe'))) {
        Write-Warning '找不到 llvm-dlltool.exe，跳过 dlltool 垫片；如果构建卡在 windows-sys 就手动处理。'
        return $null
    }

    New-Item -ItemType Directory -Force -Path $shim | Out-Null
    Copy-Item (Join-Path $mingwBin 'llvm-dlltool.exe') $shimExe -Force
    foreach ($d in 'libLLVM-23.dll', 'libwinpthread-1.dll', 'libc++.dll', 'libunwind.dll', 'libffi-8.dll') {
        $src = Join-Path $mingwBin $d
        if (Test-Path $src) { Copy-Item $src $shim -Force }
    }
    $env:PATH = "$shim;$env:PATH"
    return $shim
}

Write-Step '准备 dlltool 垫片'
$shimDir = Ensure-DlltoolShim
if ($shimDir) { Write-Host "    dlltool: $shimDir\dlltool.exe" }

# --------------------------------------------------------------------------
# 2. 检查工具链
# --------------------------------------------------------------------------
Write-Step '检查 cargo-ndk 和 rustup target'
$cargoExe = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $cargoExe) {
    throw "找不到 cargo（CARGO_HOME=$env:CARGO_HOME）。请装 Rust 或设置 CARGO_HOME。"
}
if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    throw "找不到 rustup（CARGO_HOME=$env:CARGO_HOME）。脚本需要 rustup 来检查和切换 target。"
}
$null = & cargo ndk --version 2>&1
if ($LASTEXITCODE -ne 0) {
    throw 'cargo-ndk 没装。安装：cargo install cargo-ndk'
}

# 注意工具链的解析顺序：core/rust-toolchain.toml 里写的是 channel = "stable"，
# 不带 host 后缀，rustup 会解析成**本机默认 host**（这台机器是 msvc），
# 而 Android target 只装在了 gnu 工具链上。所以不能只看 `rustup target list`，
# 得在 $CoreDir 目录里问、并且在目标缺失时换到装了这些 target 的工具链。
function Get-TargetsFor {
    param([string]$Toolchain)
    $rustupArgs = @('target', 'list', '--installed')
    if ($Toolchain) { $rustupArgs += @('--toolchain', $Toolchain) }
    Push-Location $CoreDir
    try { return @(& rustup @rustupArgs 2>&1) } finally { Pop-Location }
}

$requiredTargets = @($Abis | ForEach-Object { $AbiToTarget[$_] })
foreach ($abi in $Abis) {
    if (-not $AbiToTarget.ContainsKey($abi)) {
        throw "未知 ABI '$abi'（支持：$($AbiToTarget.Keys -join ', ')）"
    }
}

Push-Location $CoreDir
try {
    $activeLine = (& rustup show active-toolchain 2>&1) -join ' '
} finally { Pop-Location }
Write-Host "    工具链: $activeLine"

$missing = @($requiredTargets | Where-Object { (Get-TargetsFor) -notcontains $_ })
if ($missing.Count -gt 0) {
    # 当前工具链缺 target：找一个装齐了的工具链顶上（不改仓库里的任何文件）
    Write-Host "    当前工具链缺 target：$($missing -join ', ')，尝试换工具链" -ForegroundColor Yellow
    $candidates = @(& rustup toolchain list 2>&1 |
        ForEach-Object { ($_ -split '\s+')[0] } |
        Where-Object { $_ -and $_ -notmatch '^-' })
    $switched = $null
    foreach ($tc in $candidates) {
        $have = @(Get-TargetsFor -Toolchain $tc)
        $stillMissing = @($requiredTargets | Where-Object { $have -notcontains $_ })
        if ($stillMissing.Count -eq 0) { $switched = $tc; break }
    }
    if (-not $switched) {
        throw @"
没有任何已安装的 rustup 工具链带齐这些 target：$($requiredTargets -join ', ')
当前工具链：$activeLine

装到哪个工具链就显式指定，例如（宿主机是 windows-gnu 时）：
  rustup target add --toolchain stable-x86_64-pc-windows-gnu $($requiredTargets -join ' ')
  `$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-gnu'
"@
    }
    $env:RUSTUP_TOOLCHAIN = $switched
    Write-Host "    改用 RUSTUP_TOOLCHAIN=$switched（它有全部需要的 target）" -ForegroundColor Yellow
} else {
    Write-Host "    target 齐全：$($requiredTargets -join ', ')"
}

# --------------------------------------------------------------------------
# 3. 编译
# --------------------------------------------------------------------------
$targetArgs = @()
foreach ($abi in $Abis) { $targetArgs += @('-t', $abi) }

Write-Step "cargo ndk build（profile=$Profile, platform=$Platform, abis=$($Abis -join ','))"
Push-Location $CoreDir
try {
    & cargo ndk @targetArgs --platform $Platform -o $JniLibs build --profile $Profile -p lekis-ffi
    if ($LASTEXITCODE -ne 0) { throw "cargo ndk 构建失败（exit $LASTEXITCODE）" }
} finally {
    Pop-Location
}

# --------------------------------------------------------------------------
# 4. 结果
# --------------------------------------------------------------------------
Write-Step '生成的 .so'
$rows = @()
foreach ($abi in $Abis) {
    $path = Join-Path $JniLibs (Join-Path $abi $LibName)
    if (-not (Test-Path $path)) { Write-Warning "缺少 $abi/$LibName"; continue }
    $item = Get-Item $path
    $machineOk = ''
    if ($Verify) {
        # ELF 头：偏移 18 是 e_machine（小端 2 字节）
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $machine = [BitConverter]::ToUInt16($bytes, 18)
        $machineOk = if ($machine -eq $AbiToMachine[$abi]) { 'ok' } else { "BAD(0x{0:x})" -f $machine }
    }
    $rows += [pscustomobject]@{
        ABI    = $abi
        SizeMB = [math]::Round($item.Length / 1MB, 2)
        Bytes  = $item.Length
        Elf    = $machineOk
        Path   = $item.FullName
    }
}
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$total = ($rows | Measure-Object Bytes -Sum).Sum
Write-Host ("合计 {0} 个 ABI，{1:N2} MB" -f $rows.Count, ($total / 1MB)) -ForegroundColor Green
Write-Host "输出目录：$JniLibs"

# cargo-ndk 会把本次构建产出的**所有** cdylib 一起拷进 jniLibs，不只是 lekis-ffi。
# 依赖里如果有 crate-type 带 cdylib 的（比如 zhconv），这里会多出带 hash 后缀的
# libxxx-<hash>.so，App 并不加载它们（真正的代码已经静态链进 liblekis_ffi.so）。
$others = @(Get-ChildItem $JniLibs -Recurse -Filter '*.so' |
    Where-Object { $_.Name -ne $LibName } | Sort-Object FullName)
if ($others.Count -gt 0) {
    Write-Host "另外 cargo-ndk 还顺带拷了 $($others.Count) 个依赖的 cdylib（App 不加载，可忽略）：" -ForegroundColor DarkGray
    $others | ForEach-Object {
        Write-Host ("    {0,-52} {1,8:N0} B" -f ($_.FullName.Substring($JniLibs.Length + 1)), $_.Length) -ForegroundColor DarkGray
    }
}

# --------------------------------------------------------------------------
# 5. Kotlin 绑定新鲜度检查
#    Rust 侧 #[uniffi::export] 变了但 Kotlin 绑定没重新生成，编译期不报错，
#    运行期才会 NoSuchMethod/UnsatisfiedLinkError。这里直接比对符号：
#    绑定里调用的 uniffi_lekis_ffi_* 必须都在 .so 里导出。
# --------------------------------------------------------------------------
Write-Step 'Kotlin 绑定新鲜度'
$bindingFile = Join-Path $Root 'apps\android\core\bridge\src\main\kotlin\uniffi\lekis_ffi\lekis_ffi.kt'
if (-not (Test-Path $bindingFile)) {
    Write-Host "    绑定还没生成：pwsh -File tools/gen-bindings.ps1" -ForegroundColor Yellow
} else {
    $probeAbi = $Abis | Where-Object { Test-Path (Join-Path $JniLibs (Join-Path $_ $LibName)) } | Select-Object -First 1
    $soPath = Join-Path $JniLibs (Join-Path $probeAbi $LibName)
    $soBytes = [System.IO.File]::ReadAllBytes($soPath)
    # 直接在二进制里找符号名（-Verify 之外不想依赖 llvm-nm 一定存在）
    $soText = [System.Text.Encoding]::ASCII.GetString($soBytes)
    $wanted = [regex]::Matches((Get-Content $bindingFile -Raw), 'fun (uniffi_lekis_ffi_[a-z0-9_]+)\(') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $gone = @($wanted | Where-Object { -not $soText.Contains($_) })
    if ($gone.Count -gt 0) {
        Write-Host "    绑定落后于 .so：$($gone.Count)/$($wanted.Count) 个符号在 .so 里找不到" -ForegroundColor Yellow
        $gone | Select-Object -First 5 | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
        Write-Host "    重新生成：pwsh -File tools/gen-bindings.ps1" -ForegroundColor Yellow
    } else {
        Write-Host "    ok（$($wanted.Count) 个绑定符号都能在 .so 里找到）" -ForegroundColor Green
    }
}

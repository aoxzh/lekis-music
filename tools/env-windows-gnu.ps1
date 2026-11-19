# Lekis 开发环境变量（Windows / GNU 工具链）
#
# 用法（PowerShell）：
#   . .\tools\env-windows-gnu.ps1            # 用下面的默认路径
#   $env:LEKIS_GNU_DLLTOOL_DIR = 'D:\msys64\ucrt64\bin'; . .\tools\env-windows-gnu.ps1
#   $env:LEKIS_LLVM_MINGW_DIR = 'D:\llvm-mingw\bin';      . .\tools\env-windows-gnu.ps1
#
# 背景（三个坑，都是实测踩出来的）：
#
# 1. rustc 的 x86_64-pc-windows-gnu 目标自带一个 self-contained 的 dlltool，它会去调一个
#    并不存在的 GNU `as`，于是链接 getrandom / windows-sys 时报
#    "dlltool could not create import library"。必须用 -Cdlltool=<dir>\dlltool.exe 换掉它。
#
# 2. **不能用 llvm-dlltool 顶替**：它能生成 import library，编译链接全都成功，但生成的
#    import 表在运行期是坏的 —— 任何链接了 windows-sys / windows crate 的程序（cpal 走
#    WASAPI、COM 初始化、甚至只是 static 链接进去没调用）一启动就 STATUS_ACCESS_VIOLATION
#    (0xc0000005)，连 main 的第一行都执行不到。用真 GNU binutils 的 dlltool 就正常。
#    MSYS2 里装：pacman -Sy --noconfirm mingw-w64-ucrt-x86_64-binutils
#    于是这个脚本优先找 GNU dlltool（$LEKIS_GNU_DLLTOOL_DIR，默认 C:\msys64\ucrt64\bin），
#    找不到才退回 llvm-dlltool（能编译，但运行期会崩，只适合纯 Rust 无 Windows API 的检查）。
#
# 3. 需要编译 C 代码的 crate（ring、*-sys）用 clang 当 CC。
#    **不要**把 llvm-mingw\bin 加进 PATH：里面的 x86_64-w64-mingw32-gcc.exe 是 clang 的包装，
#    会抢走 rustc 默认的链接驱动，然后报找不到 -lgcc / -lgcc_eh。

if (-not $env:LEKIS_CARGO_HOME) { $env:LEKIS_CARGO_HOME = Join-Path $env:USERPROFILE 'dev\cargo' }
if (-not $env:LEKIS_RUSTUP_HOME) { $env:LEKIS_RUSTUP_HOME = Join-Path $env:USERPROFILE 'dev\rustup' }
if (-not $env:LEKIS_LLVM_MINGW_DIR) {
    $candidate = Get-ChildItem -Path (Join-Path $env:USERPROFILE 'dev\toolchains\llvm-mingw') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($candidate) { $env:LEKIS_LLVM_MINGW_DIR = Join-Path $candidate.FullName 'bin' }
}
if (-not $env:LEKIS_GNU_DLLTOOL_DIR) {
    foreach ($d in @('C:\msys64\ucrt64\bin', 'C:\msys64\mingw64\bin')) {
        if (Test-Path (Join-Path $d 'dlltool.exe')) { $env:LEKIS_GNU_DLLTOOL_DIR = $d; break }
    }
}

$env:CARGO_HOME = $env:LEKIS_CARGO_HOME
$env:RUSTUP_HOME = $env:LEKIS_RUSTUP_HOME
if (-not $env:RUSTUP_TOOLCHAIN) { $env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-gnu' }

# dlltool：GNU 优先（运行期正确），llvm 兜底（只保证能链接）。
$dlltool = $null
if ($env:LEKIS_GNU_DLLTOOL_DIR -and (Test-Path (Join-Path $env:LEKIS_GNU_DLLTOOL_DIR 'dlltool.exe'))) {
    $dlltool = Join-Path $env:LEKIS_GNU_DLLTOOL_DIR 'dlltool.exe'
    # dlltool 要靠同目录的 as.exe；保证它在 PATH 上（ucrt64/bin 不会抢 rustc 的链接驱动）。
    if (($env:Path -split ';') -notcontains $env:LEKIS_GNU_DLLTOOL_DIR) {
        $env:Path = "$($env:LEKIS_GNU_DLLTOOL_DIR);$env:Path"
    }
} elseif ($env:LEKIS_LLVM_MINGW_DIR -and (Test-Path (Join-Path $env:LEKIS_LLVM_MINGW_DIR 'llvm-dlltool.exe'))) {
    $dlltool = Join-Path $env:LEKIS_LLVM_MINGW_DIR 'llvm-dlltool.exe'
    Write-Warning '找不到 GNU dlltool（见脚本注释第 2 条），退回 llvm-dlltool：能编译，但链接了 Windows API 的程序运行时会崩。'
} else {
    Write-Warning '找不到任何 dlltool，链接会失败。装 MSYS2 binutils 或设置 LEKIS_GNU_DLLTOOL_DIR。'
}

if ($dlltool) {
    $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = "-Cdlltool=$dlltool"
}

if ($env:LEKIS_LLVM_MINGW_DIR -and (Test-Path $env:LEKIS_LLVM_MINGW_DIR)) {
    $mingw = $env:LEKIS_LLVM_MINGW_DIR
    $env:CC_x86_64_pc_windows_gnu = "$mingw\x86_64-w64-mingw32-clang.exe"
    $env:CXX_x86_64_pc_windows_gnu = "$mingw\x86_64-w64-mingw32-clang++.exe"
    $env:AR_x86_64_pc_windows_gnu = "$mingw\llvm-ar.exe"
}

$cargoBin = Join-Path $env:CARGO_HOME 'bin'
if (($env:Path -split ';') -notcontains $cargoBin) { $env:Path = "$cargoBin;$env:Path" }

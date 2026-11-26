# 在 Windows 开始菜单里创建 / 删除 "Lekis" 快捷方式（免安装构建也能从开始菜单和搜索里找到）。
#
#   tools/install-windows-shortcut.ps1                  # 指向默认的 release 构建
#   tools/install-windows-shortcut.ps1 -ExePath <路径>   # 指向别的 lekis.exe（也可以直接传它所在的目录）
#   tools/install-windows-shortcut.ps1 -Name <名字>      # 快捷方式文件名，默认 Lekis
#   tools/install-windows-shortcut.ps1 -Uninstall       # 删除快捷方式（不需要 exe 还在）
#
# 默认目标是 app\build\windows\x64\runner\Release\lekis.exe，快捷方式落在
# %APPDATA%\Microsoft\Windows\Start Menu\Programs\Lekis.lnk。
#
# 快捷方式的「起始位置」必须是 exe 所在目录：程序按相对路径找 data\（Flutter assets、icudtl.dat），
# 起始位置不对就起不来。
# 图标用 exe 自带的（app/windows/runner/resources/app_icon.ico 通过 Runner.rc 的 IDI_APP_ICON
# 编进 exe），所以 exe 里没有单独的 .ico 文件要复制。
#
# 重复运行是安全的：每次都按同样的属性重写一遍 .lnk。

param(
    [string]$ExePath = '',
    [string]$Name = '',
    [string]$StartMenuDir = '',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$isChineseUi = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'zh'
if (-not $Name) {
    $Name = if ($isChineseUi) { '月兔音乐' } else { 'Lekis Music' }
}
$root = Split-Path -Parent $PSScriptRoot
if (-not $ExePath) { $ExePath = Join-Path $root 'app\build\windows\x64\runner\Release\lekis.exe' }
$ExePath = [System.IO.Path]::GetFullPath($ExePath, (Get-Location).Path)
# 传目录也行：自动补成目录里的 lekis.exe。
if (Test-Path $ExePath -PathType Container) { $ExePath = Join-Path $ExePath 'lekis.exe' }
if (-not $StartMenuDir) { $StartMenuDir = [Environment]::GetFolderPath('Programs') }
$StartMenuDir = [System.IO.Path]::GetFullPath($StartMenuDir, (Get-Location).Path)
$lnkPath = Join-Path $StartMenuDir "$Name.lnk"

if ($Uninstall) {
    # 卸载不检查 exe：构建目录可能已经删了，快捷方式还是要能清掉。
    if (Test-Path $lnkPath) {
        Remove-Item $lnkPath -Force
        Write-Host "已删除开始菜单快捷方式：$lnkPath"
    } else {
        Write-Host "没有找到开始菜单快捷方式（无需删除）：$lnkPath"
    }
    return
}

if (-not (Test-Path $ExePath -PathType Leaf)) {
    throw "找不到 lekis.exe：$ExePath（先跑 flutter build windows --release，或用 -ExePath 指定）"
}

$releaseDir = Split-Path -Parent $ExePath
New-Item -ItemType Directory -Force $StartMenuDir | Out-Null

$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($lnkPath)
$link.TargetPath = $ExePath
$link.WorkingDirectory = $releaseDir
$link.IconLocation = "$ExePath,0"
$link.Description = if ($isChineseUi) { '月兔音乐' } else { 'Lekis Music' }
$link.WindowStyle = 1
$link.Save()
$null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)

Write-Host "已创建开始菜单快捷方式：$lnkPath"
Write-Host "  目标：$ExePath"
Write-Host "  起始位置：$releaseDir"
Write-Host "  图标：$ExePath,0"

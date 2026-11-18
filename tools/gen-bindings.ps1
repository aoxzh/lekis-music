# Windows 版的 gen-bindings.sh（说明见那个文件）。
$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location (Join-Path $Root 'core')
try {
    cargo build -p lekis-ffi
    if ($LASTEXITCODE -ne 0) { throw 'cargo build failed' }
    $Lib = 'target\debug\lekis_ffi.dll'

    Write-Host '==> Kotlin'
    cargo run -q -p uniffi-bindgen -- generate --library $Lib --language kotlin `
        --out-dir (Join-Path $Root 'apps\android\core\bridge\src\main\kotlin') --no-format
    if ($LASTEXITCODE -ne 0) { throw 'kotlin bindgen failed' }

    Write-Host '==> C#'
    if (Get-Command uniffi-bindgen-cs -ErrorAction SilentlyContinue) {
        uniffi-bindgen-cs --library $Lib --out-dir (Join-Path $Root 'apps\windows\src\Lekis.Core.Interop\Generated')
        if ($LASTEXITCODE -ne 0) { throw 'c# bindgen failed' }
    } else {
        Write-Warning 'uniffi-bindgen-cs not installed, skipping C# bindings'
        Write-Warning '  cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.9.0+v0.28.3'
    }
} finally {
    Pop-Location
}

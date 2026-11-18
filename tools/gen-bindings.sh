#!/usr/bin/env bash
# 生成 UniFFI 绑定（ADR-0005）。lekis-ffi 的对外接口变了之后必须运行。
#   Kotlin → apps/android/core/bridge/src/main/kotlin/uniffi/lekis_ffi/
#   C#     → apps/windows/src/Lekis.Core.Interop/Generated/   （需要先安装 uniffi-bindgen-cs）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/core"

cargo build -p lekis-ffi

case "$(uname -s)" in
  Linux*) LIB=target/debug/liblekis_ffi.so ;;
  Darwin*) LIB=target/debug/liblekis_ffi.dylib ;;
  MINGW* | MSYS* | CYGWIN*) LIB=target/debug/lekis_ffi.dll ;;
  *) echo "unsupported host: $(uname -s)" >&2; exit 1 ;;
esac

echo "==> Kotlin"
cargo run -q -p uniffi-bindgen -- generate --library "$LIB" --language kotlin \
  --out-dir "$ROOT/apps/android/core/bridge/src/main/kotlin" --no-format

echo "==> C#"
if command -v uniffi-bindgen-cs >/dev/null 2>&1; then
  # 版本必须和 lekis-ffi 的 uniffi 版本对应（见 core/crates/lekis-ffi/Cargo.toml）
  uniffi-bindgen-cs --library "$LIB" --out-dir "$ROOT/apps/windows/src/Lekis.Core.Interop/Generated"
else
  echo "uniffi-bindgen-cs not installed, skipping C# bindings" >&2
  echo "  cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.9.0+v0.28.3" >&2
fi

# rquickjs-sys 0.14.0（vendored，仅为 Android 交叉编译）

这个目录是 [rquickjs-sys v0.14.0](https://crates.io/crates/rquickjs-sys/0.14.0) 的**逐文件副本**，
只做了一处改动：在 `src/bindings/` 下补了三个 Android 绑定文件。

## 为什么需要它

`rquickjs-sys` 的 `src/lib.rs` 里有：

```rust
#[cfg(not(feature = "bindgen"))]
include!(concat!("bindings/", bindings_env!("TARGET"), ".rs"));
```

而 0.14.0 发布的 `src/bindings/` 里**没有** Android 目标：

```
aarch64-apple-darwin        aarch64-unknown-linux-musl   armv7-unknown-linux-gnueabihf
aarch64-pc-windows-msvc     armv7-unknown-linux-gnueabi  i686-unknown-linux-gnu
aarch64-unknown-linux-gnu   loongarch64-*                powerpc64-*
riscv64*                    wasm32-*                     x86_64-{apple-darwin,pc-windows-gnu,pc-windows-msvc,unknown-linux-*}
```

所以 `cargo ndk ... build -p lekis-bridge` 会在编译 `rquickjs-sys` 时报：

```
error: couldn't find file `.../rquickjs-sys-0.14.0/src/bindings/aarch64-linux-android.rs`
error: could not compile `rquickjs-sys` (lib) due to 1 previous error
```

上游提供的替代方案是 `bindgen` feature，但那需要 **libclang**：本机没有 LLVM 发行版，
NDK 27.2 的 `toolchains/llvm/prebuilt/windows-x86_64/` 也只带 clang 可执行文件、不带 `libclang.dll`，
所以走不通。

## 补的绑定文件从哪来

`quickjs.h` 的这些绑定在相同 ABI 布局的目标之间是等价的（已用 `clang -dM -E` 核对
`__SIZEOF_POINTER__` / `__SIZEOF_LONG__` / `__SIZEOF_LONG_DOUBLE__` / `__BYTE_ORDER__`）：

| Android target | 复制自 | 依据 |
| --- | --- | --- |
| `aarch64-linux-android` | `aarch64-unknown-linux-gnu.rs` | LP64、`long double` 16 字节、小端；与 `x86_64-unknown-linux-gnu.rs` 逐字节相同 |
| `x86_64-linux-android` | `aarch64-unknown-linux-gnu.rs` | 同上（64 位绑定文件之间字节一致） |
| `armv7-linux-androideabi` | `armv7-unknown-linux-gnueabihf.rs` | 32 位、`long double` 8 字节、`JS_NAN_BOXING=1` |

> 注意：armv7 必须用 `gnueabihf.rs` 那份。同目录的 `armv7-unknown-linux-gnueabi.rs` 是**旧版
> quickjs.h 的产物**（缺 `JS_PromiseThen`、还留着已删除的 `js_realloc2`），拿它编会链接失败。
> 判断方法：`armv7-unknown-linux-gnueabihf.rs` 与 `i686-unknown-linux-gnu.rs` 内容才是和当前
> `quickjs.h` 对应的版本。

## 对桌面端的影响

- `[patch.crates-io]` 对**所有**目标生效，桌面构建也走这份 vendored 源码，但除新增的三个
  Android 文件外，其余 90 个文件的字节与 crates.io 上的 0.14.0 完全一致，因此桌面行为不变。
- 已删除与本 crate 编译无关的目录以减小仓库体积：`quickjs/docs`、`quickjs/examples`、
  `quickjs/tests`、`quickjs/.github`、`quickjs/gen`、`vendor/wasi-libc`（2.5 MB，仅 WASI 目标用）、
  `wasm-shim`（仅 `wasm32-unknown-unknown` 用）、`.gitignore`、`.cargo_vcs_info.json`。
  `build.rs` 需要的 4 个 C 源文件和 14 个头文件全部保留。
- 如果将来升级 `rquickjs`：先删掉这个目录和 `core/Cargo.toml` 里的 `[patch.crates-io]`，
  再确认新版是否已自带 Android 绑定；如果仍然没有，就按同一张表重新复制。

## 怎么确认这份 vendor 是干净的

```powershell
# 与 crates.io 上的 0.14.0 逐字节比对（除了三个 *-android.rs）
$src = "$env:CARGO_HOME\registry\src\index.crates.io-1949cf8c6b5b557f\rquickjs-sys-0.14.0"
robocopy $src core\vendor\rquickjs-sys /L /E /NJH /NJS | Select-String '\*EXTRA'
```

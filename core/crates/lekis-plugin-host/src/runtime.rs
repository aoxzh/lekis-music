//! 插件运行时。
//!
//! - [`JsRuntime`]：QuickJS（rquickjs），1.0 实现。每个插件一个独立的 JS 上下文，
//!   插件源码必须已经是 JS（TS 转译在插件打包阶段完成，宿主不内置 swc / oxc）；
//! - WASM 运行时：1.x 实现，接口见 `plugin-sdk/wit/lekis-plugin.wit`。
//!
//! 每次调用都有超时（默认 15 秒）、内存上限（默认 64MB）。插件崩溃不能影响 App。
//!
//! # 实现要点
//!
//! - **一次性上下文**：`rquickjs::Runtime` / `Context` 不是 `Send`，而 [`PluginRuntime::call`]
//!   是 `&self` 且可能被多个任务并发调用。所以每次调用都在 `spawn_blocking` 的线程里
//!   **从源码重建**一个运行时：一次调用一个全新堆，插件写崩、超时、内存爆掉都只影响这次调用，
//!   下一次调用仍然是干净的。同一插件的调用再用一把异步锁串行化（避免同时跑多份插件进程内状态，
//!   也让超时处理更可控）——代价是一个慢调用会挡住同一插件的其它调用，可以接受。
//! - **同步执行 + 手动跑微任务队列**：QuickJS 本身是同步的。插件的 `async` 函数返回 Promise，
//!   我们用 `Promise::finish()` 反复执行 QuickJS 的 job 队列直到 Promise 落定。
//!   因为宿主 API（`host.http` 等）在 Rust 侧是同步阻塞的，所以插件 `await host.http...`
//!   一定能落定；如果插件自己 `await` 一个永远不落定的东西（比如等外部事件），
//!   队列会空掉，这时返回错误而不是挂死（见 [`JsRuntime`] 的“已知限制”）。MyGO
//!   兼容层另外提供有界的 fetch/timer 事件队列，在同一调用期限内驱动。
//! - **超时**：`Runtime::set_interrupt_handler` + deadline。QuickJS 在执行 JS 期间会定期回调它，
//!   返回 `true` 就抛一个不可捕获的异常并让出控制权。注意它只对 JS 代码生效：如果插件卡在
//!   宿主 API 里（比如 HTTP 请求），靠的是请求自身的超时。
//! - **内存**：`Runtime::set_memory_limit(64MB)`，超出后 QuickJS 抛 OOM 错误，不会拖垮宿主。
//! - **模块/脚本双模式**：插件 SDK 约定是 ES 模块（`export function search(...)`），但也接受
//!   在全局作用域直接 `function search(...)` 的普通脚本：先按脚本求值，若失败且源码里出现
//!   `export` / `import` 关键字，再按 ES 模块求值。关键字识别会跳过注释和字符串字面量。

use crate::js_host::{install, HostBridge, HttpTransport, ReqwestTransport};
use crate::manifest::{Capability, PluginManifest};
use crate::permission::Permissions;
use async_trait::async_trait;
use lekis_types::{ErrorCode, LekisError, Result};
use rquickjs::context::EvalOptions;
use rquickjs::{CaughtError, Context, Ctx, Function, Module, Object, Promise, Runtime, Value};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// 默认调用超时。
pub const DEFAULT_CALL_TIMEOUT: Duration = Duration::from_secs(15);

/// 每个插件运行时的内存上限（64MB）。
pub const MEMORY_LIMIT: usize = 64 * 1024 * 1024;

/// JS 栈大小上限。默认 256KB 对递归型插件偏小，抬到 1MB。
pub const MAX_STACK_SIZE: usize = 1024 * 1024;

/// 模块名（出现在 JS 异常堆栈里）。
const MODULE_NAME: &str = "plugin.js";

/// 全部能力，按声明顺序排列（`capabilities()` 返回时按这个顺序，便于测试和展示稳定）。
const ALL_CAPABILITIES: [Capability; 10] = [
    Capability::Search,
    Capability::Browse,
    Capability::Stream,
    Capability::Lyrics,
    Capability::Artwork,
    Capability::Playlist,
    Capability::Album,
    Capability::Artist,
    Capability::Scrobble,
    Capability::ImportPlaylist,
];

/// 插件抛出的结构化错误（PLG-07）。界面据此引导用户。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PluginError {
    /// 需要登录。
    SignIn,
    /// 需要先完成设置。
    Setup,
    /// 内容暂时不可用。
    Unavailable,
    /// 插件不支持这个操作。
    Unsupported,
    /// 被限流，稍后再试。
    RateLimited,
}

impl From<PluginError> for LekisError {
    fn from(e: PluginError) -> Self {
        let code = match e {
            PluginError::SignIn => ErrorCode::Auth,
            PluginError::Setup => ErrorCode::InvalidArgument,
            PluginError::Unavailable => ErrorCode::NotFound,
            PluginError::Unsupported => ErrorCode::Unsupported,
            PluginError::RateLimited => ErrorCode::RateLimited,
        };
        LekisError::new(code, format!("plugin error: {e:?}"))
    }
}

/// 从 JS 里的 `code` 字段映射到结构化错误。
///
/// 这些字符串和 `plugin-sdk/js/src/index.ts` 里的 `PluginErrorCode` 一致，
/// 宿主自己的 API 抛的也是同一组字符串，所以插件可以统一 `catch`。
fn plugin_error_from_code(code: &str) -> Option<PluginError> {
    match code {
        "signIn" => Some(PluginError::SignIn),
        "setup" => Some(PluginError::Setup),
        "unavailable" => Some(PluginError::Unavailable),
        "unsupported" => Some(PluginError::Unsupported),
        "rateLimited" => Some(PluginError::RateLimited),
        _ => None,
    }
}

/// 能力对应的 JS 导出函数名。
fn capability_name(capability: Capability) -> &'static str {
    match capability {
        Capability::Search => "search",
        Capability::Browse => "browse",
        Capability::Stream => "stream",
        Capability::Lyrics => "lyrics",
        Capability::Artwork => "artwork",
        Capability::Playlist => "playlist",
        Capability::Album => "album",
        Capability::Artist => "artist",
        Capability::Scrobble => "scrobble",
        Capability::ImportPlaylist => "importPlaylist",
    }
}

/// 粗略判断源码是不是 ES 模块：注释和字符串之外出现 `export` / `import` 关键字。
///
/// 只在“按脚本求值失败”之后才用它决定要不要改按模块重试，所以误判的代价很低。
fn looks_like_module(source: &str) -> bool {
    let bytes = source.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        let byte = bytes[index];
        match byte {
            // 行注释
            b'/' if bytes.get(index + 1) == Some(&b'/') => {
                index += 2;
                while index < bytes.len() && bytes[index] != b'\n' {
                    index += 1;
                }
            }
            // 块注释
            b'/' if bytes.get(index + 1) == Some(&b'*') => {
                index += 2;
                while index + 1 < bytes.len() && !(bytes[index] == b'*' && bytes[index + 1] == b'/')
                {
                    index += 1;
                }
                index = (index + 2).min(bytes.len());
            }
            // 字符串（含模板字符串，简单处理：不当成嵌套）
            b'"' | b'\'' | b'`' => {
                let quote = byte;
                index += 1;
                while index < bytes.len() {
                    match bytes[index] {
                        b'\\' => index += 2,
                        b if b == quote => {
                            index += 1;
                            break;
                        }
                        _ => index += 1,
                    }
                }
            }
            // 标识符
            b if b.is_ascii_alphabetic() || b == b'_' || b == b'$' => {
                let start = index;
                while index < bytes.len()
                    && (bytes[index].is_ascii_alphanumeric()
                        || bytes[index] == b'_'
                        || bytes[index] == b'$')
                {
                    index += 1;
                }
                let word = &source[start..index];
                if word == "export" || word == "import" {
                    return true;
                }
            }
            _ => index += 1,
        }
    }
    false
}

/// 已加载插件的能力函数表。
///
/// 只保存函数值（不保存模块对象）：模块求值完成后把 `Function` 取出来即可，
/// 后面的调用不再需要模块本身。
struct LoadedPlugin<'js> {
    functions: Vec<(Capability, Function<'js>)>,
}

impl<'js> LoadedPlugin<'js> {
    /// 取某个能力的导出函数。
    fn function(&self, capability: Capability) -> Option<&Function<'js>> {
        self.functions
            .iter()
            .find(|(found, _)| *found == capability)
            .map(|(_, function)| function)
    }
}

/// 已加载的插件实例。
#[async_trait]
pub trait PluginRuntime: Send + Sync {
    /// 清单。
    fn manifest(&self) -> &PluginManifest;

    /// 插件实际导出了哪些能力（加载时检查导出函数得到）。
    fn capabilities(&self) -> &[Capability];

    /// 调用一个能力。参数和返回值都是 JSON 对象，结构见 `plugin-sdk/js/src/index.ts`。
    async fn call(
        &self,
        capability: Capability,
        params: serde_json::Value,
    ) -> Result<serde_json::Value>;
}

/// JS 运行时。
///
/// 构造之后不可变；`call` 可以从任意线程、任意任务并发调用。每次调用都会用
/// 加载时保存的入口源码新建一个 QuickJS 运行时，所以插件状态（全局变量等）**不跨调用保留**。
/// 需要跨调用保留的东西必须走 `host.storage` / `host.setting`，它们由
/// [`HostBridge`] 保存，生命周期和 [`JsRuntime`] 一致。
///
/// # 已知限制
///
/// - **原生 API 没有事件循环**：QuickJS 是同步引擎。宿主的 `host.*` API 在 Rust 侧同步阻塞，
///   所以 `async function` / `await host.http...` 正常工作；但插件不能等「宿主以后会推过来的事件」
///   （没有 `setTimeout`、没有事件订阅）。等不到东西的 Promise 会让队列空掉，
///   [`PluginRuntime::call`] 返回错误而不是挂死。MyGO 兼容层有独立的 fetch/setTimeout
///   队列（最多 8 个请求、256 个定时器），受相同调用期限约束；不提供 setInterval。
/// - **ES 模块有限支持**：支持 `export function search(...)` 这种写法（也支持不带 `export` 的
///   全局函数脚本，两种都认）。但**不支持模块间 `import`**：没有模块解析器，
///   插件必须打包成单个文件（这和 SDK 的构建约定一致）。
/// - **状态不跨调用**：插件重装运行时，模块级的变量每次都是初始值。需要缓存就用 `host.storage`。
/// - **二进制响应**：`host.http` 目前只返回文本（`text()` / `json()` / `bytes()` 里的 bytes
///   是按 charCode 截断的低 8 位），下载音频这类二进制要等专门的下载 API。
pub struct JsRuntime {
    manifest: PluginManifest,
    permissions: Permissions,
    /// 插件入口源码。每次调用都用它重建运行时。
    source: Arc<str>,
    /// 加载时探测到的能力（已排序，见 [`ALL_CAPABILITIES`]）。
    capabilities: Vec<Capability>,
    /// 宿主 API 的落地实现（设置项、私有存储、HTTP）。
    host: Arc<HostBridge>,
    /// 单次调用超时。
    call_timeout: Duration,
    /// 串行化同一插件的调用：一个插件实例同一时刻只跑一个 JS 调用。
    gate: Arc<tokio::sync::Mutex<()>>,
}

impl std::fmt::Debug for JsRuntime {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("JsRuntime")
            .field("id", &self.manifest.id)
            .field("capabilities", &self.capabilities)
            .field("call_timeout", &self.call_timeout)
            .finish_non_exhaustive()
    }
}

impl JsRuntime {
    /// 加载插件目录下的入口文件。
    ///
    /// `source` 是入口文件的源码（TS 已经由调用方转译成 JS）。加载时会真的求值一遍，
    /// 用导出的函数名确定 [`PluginRuntime::capabilities`]；求值失败（语法错、初始化抛异常、
    /// 超时……）直接返回错误，不会 panic。
    pub fn load(manifest: PluginManifest, permissions: Permissions, source: &str) -> Result<Self> {
        Self::load_with_transport(
            manifest,
            permissions,
            source,
            Arc::new(ReqwestTransport::new()),
        )
    }

    /// 和 [`Self::load`] 一样，但可以指定 HTTP 传输层（测试里注入 mock，不会真的发请求）。
    pub fn load_with_transport(
        manifest: PluginManifest,
        permissions: Permissions,
        source: &str,
        transport: Arc<dyn HttpTransport>,
    ) -> Result<Self> {
        Self::load_configured(manifest, permissions, source, transport, None)
    }

    /// Load with a manager-owned native root and a separate platform grant.
    pub fn load_with_native(
        manifest: PluginManifest,
        permissions: Permissions,
        source: &str,
        plugin_root: std::path::PathBuf,
        granted: bool,
    ) -> Result<Self> {
        Self::load_configured(
            manifest,
            permissions,
            source,
            Arc::new(ReqwestTransport::new()),
            Some((plugin_root, granted)),
        )
    }

    fn load_configured(
        manifest: PluginManifest,
        permissions: Permissions,
        source: &str,
        transport: Arc<dyn HttpTransport>,
        native: Option<(std::path::PathBuf, bool)>,
    ) -> Result<Self> {
        let mut host = HostBridge::new(&manifest, permissions.clone(), transport);
        if let Some((root, granted)) = native {
            host.configure_native(
                root,
                manifest
                    .native
                    .as_ref()
                    .and_then(|native| native.android.clone()),
                granted,
            )?;
        }
        let host = Arc::new(host);
        let call_timeout = DEFAULT_CALL_TIMEOUT;
        let capabilities = probe_capabilities(&host, &manifest.id, source, call_timeout)?;

        tracing::info!(
            target: "plugin",
            id = %manifest.id,
            capabilities = ?capabilities
                .iter()
                .map(|c| capability_name(*c))
                .collect::<Vec<_>>(),
            "js plugin loaded"
        );

        Ok(Self {
            manifest,
            permissions,
            source: Arc::from(source),
            capabilities,
            host,
            call_timeout,
            gate: Arc::new(tokio::sync::Mutex::new(())),
        })
    }

    /// 这个实例实际拥有的权限（清单声明 ∩ 用户授予）。
    pub fn permissions(&self) -> &Permissions {
        &self.permissions
    }

    /// 改单次调用超时。主要给测试用（默认 [`DEFAULT_CALL_TIMEOUT`]）。
    pub fn set_call_timeout(&mut self, timeout: Duration) {
        self.call_timeout = timeout;
    }

    /// Snapshot plugin-private values for durable application storage.
    pub fn storage_snapshot(&self) -> Result<BTreeMap<String, String>> {
        self.host.storage_snapshot()
    }

    /// Restore persisted private values with quota checks.
    pub fn restore_storage(&self, values: BTreeMap<String, String>) -> Result<()> {
        self.host.restore_storage(values)
    }

    /// Provide the active plugin locale resource.
    pub fn set_translations(&self, values: BTreeMap<String, String>) -> Result<()> {
        self.host.set_translations(values)
    }

    /// 当前的调用超时。
    pub fn call_timeout(&self) -> Duration {
        self.call_timeout
    }
}

#[async_trait]
impl PluginRuntime for JsRuntime {
    fn manifest(&self) -> &PluginManifest {
        &self.manifest
    }

    fn capabilities(&self) -> &[Capability] {
        &self.capabilities
    }

    async fn call(
        &self,
        capability: Capability,
        params: serde_json::Value,
    ) -> Result<serde_json::Value> {
        if !self.capabilities.contains(&capability) {
            return Err(LekisError::unsupported(format!(
                "插件 {} 没有导出 {} 能力",
                self.manifest.id,
                capability_name(capability)
            )));
        }

        // 参数先序列化成 JSON 文本，进 JS 之后用 JSON.parse 还原：不用手写
        // serde_json::Value ←→ rquickjs::Value 的转换层，也不会有精度/边界值的坑。
        let params_json = serde_json::to_string(&params)
            .map_err(|e| LekisError::invalid(format!("插件参数无法序列化：{e}")))?;

        // 同一插件串行执行（见类型文档）。
        let guard = self.gate.clone().lock_owned().await;

        let host = self.host.clone();
        let source = self.source.clone();
        let manifest_id = self.manifest.id.clone();
        let timeout = self.call_timeout;

        // JS 执行是同步阻塞的，放到 blocking 线程，别占住异步执行器。
        let join = tokio::task::spawn_blocking(move || {
            let _guard = guard;
            execute(host, manifest_id, source, timeout, capability, params_json)
        })
        .await;

        match join {
            Ok(result) => result,
            Err(e) => Err(LekisError::new(
                ErrorCode::Plugin,
                format!(
                    "插件 {} 的 {} 调用线程异常退出：{e}",
                    self.manifest.id,
                    capability_name(capability)
                ),
            )),
        }
    }
}

/// 新建一个运行时：设置内存上限、栈上限和超时用的中断回调。
fn new_runtime(timeout: Duration, timed_out: &Arc<AtomicBool>) -> Result<Runtime> {
    let runtime = Runtime::new()
        .map_err(|e| LekisError::new(ErrorCode::Plugin, format!("创建 QuickJS 运行时失败：{e}")))?;
    runtime.set_memory_limit(MEMORY_LIMIT);
    runtime.set_max_stack_size(MAX_STACK_SIZE);

    let flag = timed_out.clone();
    let deadline = Instant::now() + timeout;
    runtime.set_interrupt_handler(Some(Box::new(move || {
        if Instant::now() >= deadline {
            flag.store(true, Ordering::SeqCst);
            true
        } else {
            false
        }
    })));
    Ok(runtime)
}

/// 加载期探测：真的求值一遍插件，看它导出了哪些能力。
fn probe_capabilities(
    host: &Arc<HostBridge>,
    manifest_id: &str,
    source: &str,
    timeout: Duration,
) -> Result<Vec<Capability>> {
    let timed_out = Arc::new(AtomicBool::new(false));
    let runtime = new_runtime(timeout, &timed_out)?;
    let context = Context::full(&runtime)
        .map_err(|e| LekisError::new(ErrorCode::Plugin, format!("创建 JS 上下文失败：{e}")))?;

    let result = context.with(|ctx| {
        let plugin = match prepare(&ctx, host, source, timeout, &timed_out) {
            Ok(plugin) => plugin,
            Err(caught) => {
                return Err(caught_to_leki_error(
                    &ctx,
                    manifest_id,
                    "加载",
                    caught,
                    &timed_out,
                ))
            }
        };
        Ok(ALL_CAPABILITIES
            .into_iter()
            .filter(|capability| plugin.function(*capability).is_some())
            .collect::<Vec<_>>())
    });

    // 先释放上下文，再释放运行时（Drop 顺序）。
    drop(context);
    result
}

/// 在全新的运行时里真正执行一次能力调用。
///
/// 注意：这个函数跑在 `spawn_blocking` 的线程上，里面的值（`Runtime` / `Context` / `Ctx`）
/// 都不跨线程。整体再包一层 `catch_unwind`，保证即使 rquickjs 内部断言失败（panic）
/// 也不会把宿主进程带走。
fn execute(
    host: Arc<HostBridge>,
    manifest_id: String,
    source: Arc<str>,
    timeout: Duration,
    capability: Capability,
    params_json: String,
) -> Result<serde_json::Value> {
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        execute_inner(
            &host,
            &manifest_id,
            &source,
            timeout,
            capability,
            &params_json,
        )
    }));

    match outcome {
        Ok(result) => result,
        Err(_) => Err(LekisError::new(
            ErrorCode::Plugin,
            format!(
                "插件 {} 的 {} 调用让 QuickJS 崩溃了（宿主已隔离）",
                manifest_id,
                capability_name(capability)
            ),
        )),
    }
}

/// [`execute`] 的实际内容，单独拆出来便于 `catch_unwind` 包住。
fn execute_inner(
    host: &Arc<HostBridge>,
    manifest_id: &str,
    source: &str,
    timeout: Duration,
    capability: Capability,
    params_json: &str,
) -> Result<serde_json::Value> {
    let timed_out = Arc::new(AtomicBool::new(false));
    let runtime = new_runtime(timeout, &timed_out)?;
    let context = Context::full(&runtime)
        .map_err(|e| LekisError::new(ErrorCode::Plugin, format!("创建 JS 上下文失败：{e}")))?;

    let result = context.with(
        |ctx| match prepare(&ctx, host, source, timeout, &timed_out) {
            Ok(plugin) => call_capability(
                &ctx,
                &plugin,
                capability,
                params_json,
                manifest_id,
                &timed_out,
            ),
            Err(caught) => Err(caught_to_leki_error(
                &ctx,
                manifest_id,
                "加载",
                caught,
                &timed_out,
            )),
        },
    );

    drop(context);
    result
}

/// 在上下文里注入宿主 API、执行引导脚本、求值插件源码，收集导出的能力函数。
///
/// 失败时返回 [`CaughtError`]（里面的 JS 值还在，可以读 `code` / `message`）。
fn prepare<'js>(
    ctx: &Ctx<'js>,
    host: &Arc<HostBridge>,
    source: &str,
    timeout: Duration,
    timed_out: &Arc<AtomicBool>,
) -> std::result::Result<LoadedPlugin<'js>, CaughtError<'js>> {
    let deadline = Instant::now() + timeout;
    let flag = timed_out.clone();
    let check = Function::new(ctx.clone(), move || {
        let expired = Instant::now() >= deadline;
        if expired {
            flag.store(true, Ordering::SeqCst);
        }
        expired
    })
    .map_err(|e| CaughtError::from_error(ctx, e))?;
    ctx.globals()
        .set("__lekis_check_deadline", check)
        .map_err(|e| CaughtError::from_error(ctx, e))?;
    install(ctx, host).map_err(|e| CaughtError::from_error(ctx, e))?;
    let _: Value = ctx
        .eval(crate::js_host::BOOTSTRAP_JS)
        .map_err(|e| CaughtError::from_error(ctx, e))?;

    if host.is_mygo {
        crate::mygo::install(ctx, host).map_err(|e| CaughtError::from_error(ctx, e))?;
        ctx.globals()
            .set(
                "__mygo_arch",
                if cfg!(target_arch = "aarch64") {
                    "arm64"
                } else {
                    std::env::consts::ARCH
                },
            )
            .map_err(|e| CaughtError::from_error(ctx, e))?;
        let _: Value = ctx
            .eval(crate::mygo::BOOTSTRAP)
            .map_err(|e| CaughtError::from_error(ctx, e))?;
        let namespace = eval_module(ctx, source)?;
        ctx.globals()
            .set("__mygo_exports", namespace)
            .map_err(|e| CaughtError::from_error(ctx, e))?;
        let adapted: Object = ctx
            .eval(crate::mygo::ADAPTER)
            .map_err(|e| CaughtError::from_error(ctx, e))?;
        return Ok(collect_functions(ctx, Some(adapted)));
    }

    // 先按普通脚本求值：插件 SDK 的模块写法在这个阶段会报 SyntaxError，
    // 那时再按 ES 模块重试。这样“全局函数”式插件和“export 函数”式插件都能跑。
    match eval_script(ctx, source) {
        Ok(()) => Ok(collect_functions(ctx, None)),
        Err(caught) => {
            if looks_like_module(source) {
                match eval_module(ctx, source) {
                    Ok(namespace) => Ok(collect_functions(ctx, Some(namespace))),
                    Err(module_error) => Err(module_error),
                }
            } else {
                Err(caught)
            }
        }
    }
}

/// 按全局脚本求值（`function search() {}` 这种写法，函数会挂到 `globalThis`）。
fn eval_script<'js>(ctx: &Ctx<'js>, source: &str) -> std::result::Result<(), CaughtError<'js>> {
    // `strict: false`：插件源码多数不是严格模式写的，宽松模式能接受更多写法。
    // `promise: true`：允许顶层 await。
    let mut options = EvalOptions::default();
    options.global = true;
    options.strict = false;
    options.promise = true;
    let value: Value = ctx
        .eval_with_options(source, options)
        .map_err(|e| CaughtError::from_error(ctx, e))?;
    settle_promise(ctx, value)
}

/// 按 ES 模块求值，返回模块的命名空间对象。
fn eval_module<'js>(
    ctx: &Ctx<'js>,
    source: &str,
) -> std::result::Result<Object<'js>, CaughtError<'js>> {
    let module = Module::declare(ctx.clone(), MODULE_NAME, source)
        .map_err(|e| CaughtError::from_error(ctx, e))?;
    let (module, promise) = module.eval().map_err(|e| CaughtError::from_error(ctx, e))?;
    // 没有 top-level await 的模块在 eval 之后就已经求值完成；有的话这里会返回 WouldBlock，
    // 我们当作“求值到能求值的程度”继续（导出表可能还没填满，见类型文档的已知限制）。
    match finish_promise(ctx, &promise) {
        Ok(_) => {}
        Err(rquickjs::Error::WouldBlock) => {}
        Err(e) => return Err(CaughtError::from_error(ctx, e)),
    }
    module
        .namespace()
        .map_err(|e| CaughtError::from_error(ctx, e))
}

/// Drive the compatibility event loop while a Promise waits for fetch/timers.
/// Native Lekis scripts keep their existing no-event-loop behavior.
fn finish_promise<'js>(ctx: &Ctx<'js>, promise: &Promise<'js>) -> rquickjs::Result<Value<'js>> {
    loop {
        if let Some(check) = ctx
            .globals()
            .get::<_, Option<Function>>("__lekis_check_deadline")?
        {
            if check.call::<_, bool>(())? {
                return Err(rquickjs::Exception::throw_message(
                    ctx,
                    "Plugin call deadline exceeded",
                ));
            }
        }
        match promise.finish::<Value>() {
            Err(rquickjs::Error::WouldBlock) => {
                let pending = ctx.globals().get::<_, Option<Function>>("__mygo_pending")?;
                let Some(pending) = pending else {
                    return Err(rquickjs::Error::WouldBlock);
                };
                if !pending.call::<_, bool>(())? {
                    return Err(rquickjs::Error::WouldBlock);
                }
                let tick: Function = ctx.globals().get("__mygo_tick")?;
                tick.call::<_, ()>(())?;
                std::thread::sleep(Duration::from_millis(2));
            }
            result => return result,
        }
    }
}

/// 如果 `value` 是 Promise 就把它跑到落定，否则原样返回。
fn settle_promise<'js>(
    ctx: &Ctx<'js>,
    value: Value<'js>,
) -> std::result::Result<(), CaughtError<'js>> {
    match value.try_into_promise() {
        Ok(promise) => match finish_promise(ctx, &promise) {
            Ok(_) => Ok(()),
            // 队列跑空但 Promise 还没落定：插件在等外部事件，QuickJS 里不会有下文了。
            Err(rquickjs::Error::WouldBlock) => Ok(()),
            Err(e) => Err(CaughtError::from_error(ctx, e)),
        },
        Err(_) => Ok(()),
    }
}

/// 从全局对象或者模块命名空间里收集能力函数。
fn collect_functions<'js>(ctx: &Ctx<'js>, namespace: Option<Object<'js>>) -> LoadedPlugin<'js> {
    let mut functions = Vec::new();
    for capability in ALL_CAPABILITIES {
        let name = capability_name(capability);
        let function = match &namespace {
            Some(namespace) => namespace
                .get::<_, Option<Function<'js>>>(name)
                .ok()
                .flatten(),
            None => ctx
                .globals()
                .get::<_, Option<Function<'js>>>(name)
                .ok()
                .flatten(),
        };
        if let Some(function) = function {
            functions.push((capability, function));
        }
    }
    LoadedPlugin { functions }
}

/// 调用一个能力函数，并把返回值收敛成 `serde_json::Value`。
fn call_capability<'js>(
    ctx: &Ctx<'js>,
    plugin: &LoadedPlugin<'js>,
    capability: Capability,
    params_json: &str,
    manifest_id: &str,
    timed_out: &AtomicBool,
) -> Result<serde_json::Value> {
    let name = capability_name(capability);
    let Some(function) = plugin.function(capability) else {
        return Err(LekisError::unsupported(format!(
            "插件 {manifest_id} 没有导出 {name} 能力"
        )));
    };

    let argument: Value<'js> = ctx.json_parse(params_json.to_string()).map_err(|e| {
        caught_to_leki_error(
            ctx,
            manifest_id,
            name,
            CaughtError::from_error(ctx, e),
            timed_out,
        )
    })?;

    let raw: Value<'js> = function.call((argument,)).map_err(|e| {
        caught_to_leki_error(
            ctx,
            manifest_id,
            name,
            CaughtError::from_error(ctx, e),
            timed_out,
        )
    })?;

    // async 函数返回 Promise，同步函数直接返回值；两种都接受。
    let resolved = match raw.try_into_promise() {
        Ok(promise) => finish_promise(ctx, &promise).map_err(|e| {
            caught_to_leki_error(
                ctx,
                manifest_id,
                name,
                CaughtError::from_error(ctx, e),
                timed_out,
            )
        })?,
        Err(value) => value,
    };

    match ctx.json_stringify(resolved) {
        // `undefined` / 函数在 JSON 里没有表示，按 null 处理。
        Ok(None) => Ok(serde_json::Value::Null),
        Ok(Some(text)) => {
            let text = text.to_string().map_err(|e| {
                caught_to_leki_error(
                    ctx,
                    manifest_id,
                    name,
                    CaughtError::from_error(ctx, e),
                    timed_out,
                )
            })?;
            serde_json::from_str(&text).map_err(|e| {
                LekisError::new(
                    ErrorCode::Plugin,
                    format!("插件 {manifest_id} 的 {name} 返回值不是合法 JSON：{e}"),
                )
            })
        }
        Err(e) => Err(caught_to_leki_error(
            ctx,
            manifest_id,
            name,
            CaughtError::from_error(ctx, e),
            timed_out,
        )),
    }
}

/// 「等待 Promise 落定」失败：说明插件 `await` 的东西永远不会完成。
fn blocked_error(manifest_id: &str, what: &str) -> LekisError {
    LekisError::new(
        ErrorCode::Plugin,
        format!(
            "插件 {manifest_id} 的 {what} 在等待一个宿主不会推进的 Promise（QuickJS 没有事件循环）"
        ),
    )
}

/// 超时错误。
fn timeout_error(manifest_id: &str, what: &str) -> LekisError {
    LekisError::new(
        ErrorCode::Plugin,
        format!("插件 {manifest_id} 的 {what} 调用超时，已被强制中断"),
    )
}

/// 把一个 [`CaughtError`] 映射成 [`LekisError`]。
///
/// 规则（PLG-07）：
/// 1. 中断（超时）→ 单独的错误；
/// 2. 抛出的值带 `code` 且是已知的结构化错误码 → [`PluginError`] → [`LekisError`]
///    （复用已有的 `From<PluginError>`，UI 能据此引导用户）；
/// 3. 其它（`throw new Error("x")`、抛字符串……）→ `ErrorCode::Plugin`，message 里带 JS 错误文本。
fn caught_to_leki_error<'js>(
    ctx: &Ctx<'js>,
    manifest_id: &str,
    what: &str,
    caught: CaughtError<'js>,
    timed_out: &AtomicBool,
) -> LekisError {
    if timed_out.load(Ordering::SeqCst) {
        return timeout_error(manifest_id, what);
    }
    if let CaughtError::Error(rquickjs::Error::WouldBlock) = caught {
        return blocked_error(manifest_id, what);
    }

    let (code, detail) = read_error_parts(ctx, &caught);
    let detail = detail
        .filter(|text| !text.is_empty())
        .unwrap_or_else(|| caught.to_string());

    if let Some(plugin_error) = code.as_deref().and_then(plugin_error_from_code) {
        let mut error = LekisError::from(plugin_error);
        error.message = format!("插件 {manifest_id} 的 {what}：{detail}");
        return error;
    }

    LekisError::new(
        ErrorCode::Plugin,
        format!("插件 {manifest_id} 的 {what} 失败：{detail}"),
    )
}

/// 从捕获到的 JS 错误里读出 `code` 与错误文本。
fn read_error_parts<'js>(
    ctx: &Ctx<'js>,
    caught: &CaughtError<'js>,
) -> (Option<String>, Option<String>) {
    match caught {
        CaughtError::Exception(exception) => {
            let object = exception.as_object();
            let code = object.get::<_, Option<String>>("code").ok().flatten();
            let detail = exception
                .message()
                .or_else(|| exception.stack())
                .or_else(|| object.get::<_, Option<String>>("name").ok().flatten());
            (code, detail)
        }
        CaughtError::Value(value) => {
            let code = value
                .as_object()
                .and_then(|object| object.get::<_, Option<String>>("code").ok().flatten());
            let detail = value
                .as_object()
                .and_then(|object| object.get::<_, Option<String>>("message").ok().flatten())
                .or_else(|| value.as_string().and_then(|text| text.to_string().ok()))
                .or_else(|| {
                    ctx.json_stringify(value.clone())
                        .ok()
                        .flatten()
                        .and_then(|text| text.to_string().ok())
                });
            (code, detail)
        }
        CaughtError::Error(error) => (None, Some(error.to_string())),
    }
}

#[cfg(test)]
mod tests {
    //! 这些用例都**真的执行 JS**（没有 mock QuickJS）。
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use crate::js_host::{HostError, HttpRequest, HttpResponse};
    use serde_json::json;
    use std::collections::BTreeMap;
    use std::sync::Mutex;

    /// mock 传输层：记录请求，返回构造时给的文本，绝不真的发网络请求。
    struct MockTransport {
        calls: Mutex<Vec<HttpRequest>>,
        response: HttpResponse,
    }

    impl MockTransport {
        fn new(text: &str) -> Self {
            Self {
                calls: Mutex::new(Vec::new()),
                response: HttpResponse {
                    status: 200,
                    headers: BTreeMap::new(),
                    text: text.to_string(),
                },
            }
        }

        fn calls(&self) -> Vec<HttpRequest> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl HttpTransport for MockTransport {
        fn fetch(&self, request: HttpRequest) -> std::result::Result<HttpResponse, HostError> {
            self.calls.lock().unwrap().push(request);
            Ok(self.response.clone())
        }
    }

    fn manifest(network: &[&str]) -> PluginManifest {
        let hosts = network
            .iter()
            .map(|host| format!("\"{host}\""))
            .collect::<Vec<_>>()
            .join(",");
        let json = format!(
            r#"{{"id":"dev.lekis.test","name":"测试插件","version":"1.0.0","apiVersion":"1.0",
                "minAppVersion":"0.1.0","runtime":"js","entry":"index.js","kinds":["source"],
                "permissions":{{"network":[{hosts}]}}}}"#
        );
        PluginManifest::parse(&json).unwrap()
    }

    fn runtime(network: &[&str], source: &str) -> JsRuntime {
        let manifest = manifest(network);
        let permissions = Permissions::new(&manifest.permissions, &[]);
        JsRuntime::load(manifest, permissions, source).unwrap()
    }

    fn runtime_with_transport(
        network: &[&str],
        source: &str,
        transport: Arc<dyn HttpTransport>,
    ) -> JsRuntime {
        let manifest = manifest(network);
        let permissions = Permissions::new(&manifest.permissions, &[]);
        JsRuntime::load_with_transport(manifest, permissions, source, transport).unwrap()
    }

    /// 普通脚本式插件（无 `export`）：能力函数挂在全局对象上。
    const SEARCH_SCRIPT: &str = r#"
        function search(params) {
            return { tracks: [{ id: "1", title: params.query }] };
        }
    "#;

    #[tokio::test]
    async fn script_plugin_runs_and_reports_capabilities() {
        let runtime = runtime(&[], SEARCH_SCRIPT);
        assert_eq!(runtime.capabilities(), &[Capability::Search]);
        assert_eq!(runtime.manifest().id, "dev.lekis.test");

        let result = runtime
            .call(Capability::Search, json!({ "query": "晴天" }))
            .await
            .unwrap();
        assert_eq!(
            result,
            json!({ "tracks": [{ "id": "1", "title": "晴天" }] })
        );
    }

    #[tokio::test]
    async fn es_module_plugin_exports_are_detected() {
        let source = r#"
            export function lyrics({ track }) {
                return { format: "plain", content: "歌词：" + track.title };
            }
        "#;
        let runtime = runtime(&[], source);
        assert_eq!(runtime.capabilities(), &[Capability::Lyrics]);

        let result = runtime
            .call(
                Capability::Lyrics,
                json!({ "track": { "title": "晴天", "artists": ["周杰伦"] } }),
            )
            .await
            .unwrap();
        assert_eq!(
            result,
            json!({ "format": "plain", "content": "歌词：晴天" })
        );

        // 没导出的能力不能调用。
        let error = runtime
            .call(Capability::Search, json!({}))
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Unsupported);
    }

    #[tokio::test]
    async fn async_plugin_is_awaited_and_storage_persists_across_calls() {
        let source = r#"
            async function search(params) {
                await host.storage.set("last", params.query);
                return { tracks: [], next: "cursor-2" };
            }
            async function lyrics() {
                const value = await host.storage.get("last");
                return { format: "plain", content: String(value) };
            }
        "#;
        let runtime = runtime(&[], source);
        assert_eq!(
            runtime.capabilities(),
            &[Capability::Search, Capability::Lyrics]
        );

        runtime
            .call(Capability::Search, json!({ "query": "七里香" }))
            .await
            .unwrap();
        // 第二次调用是全新的 JS 堆，但 host.storage 里的值还在。
        let result = runtime.call(Capability::Lyrics, json!({})).await.unwrap();
        assert_eq!(result, json!({ "format": "plain", "content": "七里香" }));
    }

    #[tokio::test]
    async fn structured_error_maps_to_auth() {
        let runtime = runtime(&[], r#"function search() { throw { code: "signIn" }; }"#);
        let error = runtime
            .call(Capability::Search, json!({}))
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Auth, "message: {}", error.message);
    }

    #[tokio::test]
    async fn structured_error_from_plugin_error_class() {
        let runtime = runtime(
            &[],
            r#"function search() { throw new PluginError("rateLimited", "太快了"); }"#,
        );
        let error = runtime
            .call(Capability::Search, json!({}))
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::RateLimited);
        assert!(
            error.message.contains("太快了"),
            "message: {}",
            error.message
        );
    }

    #[tokio::test]
    async fn plain_error_maps_to_plugin_error() {
        let runtime = runtime(&[], r#"function search() { throw new Error("boom"); }"#);
        let error = runtime
            .call(Capability::Search, json!({}))
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Plugin);
        assert!(error.message.contains("boom"), "message: {}", error.message);
    }

    #[tokio::test]
    async fn syntax_error_is_reported_at_load() {
        let manifest = manifest(&[]);
        let permissions = Permissions::new(&manifest.permissions, &[]);
        let error = JsRuntime::load(manifest, permissions, "function search( {").unwrap_err();
        assert_eq!(error.code, ErrorCode::Plugin);
        assert!(error.message.contains("加载"), "message: {}", error.message);
    }

    #[tokio::test]
    async fn infinite_loop_is_interrupted_by_timeout() {
        let mut runtime = runtime(&[], r#"function search() { while (true) {} }"#);
        runtime.set_call_timeout(Duration::from_millis(300));

        let started = Instant::now();
        let error = runtime
            .call(Capability::Search, json!({}))
            .await
            .unwrap_err();
        let elapsed = started.elapsed();

        assert_eq!(error.code, ErrorCode::Plugin);
        assert!(error.message.contains("超时"), "message: {}", error.message);
        assert!(elapsed < Duration::from_secs(10), "耗时 {elapsed:?}");

        // 超时之后同一个实例还能继续用（每次调用都是新运行时）。
        assert_eq!(runtime.capabilities(), &[Capability::Search]);
    }

    #[tokio::test]
    async fn rejects_http_to_hosts_outside_whitelist() {
        let transport = Arc::new(MockTransport::new("{}"));
        let source = r#"
            async function search() {
                await host.http.get("https://evil.example.com/steal");
                return { tracks: [] };
            }
        "#;
        let runtime = runtime_with_transport(&["lrclib.net"], source, transport.clone());
        let error = runtime
            .call(Capability::Search, json!({}))
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Unsupported);
        assert!(transport.calls().is_empty(), "白名单外的请求不能真的发出去");
    }

    #[tokio::test]
    #[ignore = "live public QQ Music endpoints"]
    async fn qq_lyrics_example_live() {
        let source = include_str!("../../../../plugin-sdk/examples/qq-lyrics/index.js");
        let runtime = runtime(&["c.y.qq.com"], source);
        let result = runtime
            .call(
                Capability::Lyrics,
                json!({"track":{"title":"晴天","artists":["周杰伦"],"durationMs":269000}}),
            )
            .await
            .unwrap();
        assert_eq!(result["format"], "lrc");
        assert!(!result["content"].as_str().unwrap().is_empty());
    }

    #[tokio::test]
    async fn qq_lyrics_example_matches_before_fetching() {
        struct QqTransport;
        impl HttpTransport for QqTransport {
            fn fetch(&self, request: HttpRequest) -> std::result::Result<HttpResponse, HostError> {
                let text = if request.url.contains("client_search_cp") {
                    r#"{"code":0,"data":{"song":{"list":[{"songname":"晴天","songmid":"mid1","interval":269,"singer":[{"name":"周杰伦"}]}]}}}"#
                } else {
                    assert!(request.url.contains("songmid=mid1"));
                    assert_eq!(
                        request.headers.get("Referer").map(String::as_str),
                        Some("https://y.qq.com/")
                    );
                    r#"{"code":0,"lyric":"[00:01.00]line"}"#
                };
                Ok(HttpResponse {
                    status: 200,
                    headers: BTreeMap::new(),
                    text: text.into(),
                })
            }
        }
        let source = include_str!("../../../../plugin-sdk/examples/qq-lyrics/index.js");
        let runtime = runtime_with_transport(&["c.y.qq.com"], source, Arc::new(QqTransport));
        let result = runtime
            .call(
                Capability::Lyrics,
                json!({"track": {"title":"晴天", "artists":["周杰伦"], "durationMs":269000}}),
            )
            .await
            .unwrap();
        assert_eq!(result["content"], "[00:01.00]line");
        let result = runtime
            .call(
                Capability::Lyrics,
                json!({"track": {"title":"wrong", "artists":["周杰伦"]}}),
            )
            .await
            .unwrap();
        assert!(result.is_null());
    }

    #[tokio::test]
    async fn allowed_http_goes_through_transport() {
        let transport = Arc::new(MockTransport::new(r#"{"plainLyrics":"第一行歌词"}"#));
        let source = r#"
            async function lyrics(params) {
                const response = await host.http.get("https://lrclib.net/api/get", {
                    query: { track_name: params.track.title, limit: 1 },
                });
                if (response.status !== 200) {
                    throw { code: "unavailable", message: "status " + response.status };
                }
                const data = await response.json();
                return { format: "plain", content: data.plainLyrics };
            }
        "#;
        let runtime = runtime_with_transport(&["lrclib.net"], source, transport.clone());
        let result = runtime
            .call(
                Capability::Lyrics,
                json!({ "track": { "title": "晴天", "artists": ["周杰伦"] } }),
            )
            .await
            .unwrap();
        assert_eq!(
            result,
            json!({ "format": "plain", "content": "第一行歌词" })
        );

        let calls = transport.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].method, "GET");
        assert!(calls[0].url.starts_with("https://lrclib.net/api/get?"));
        assert!(calls[0].url.contains("limit=1"));
    }

    #[tokio::test]
    async fn host_helpers_are_available() {
        let source = r#"
            function search() {
                host.setting("preferSynced", true);
                host.log.info("hello from plugin");
                return {
                    tracks: [],
                    next: host.t("plugin.more"),
                    setting: host.setting("preferSynced"),
                    platform: host.app.platform,
                };
            }
        "#;
        let runtime = runtime(&[], source);
        let result = runtime.call(Capability::Search, json!({})).await.unwrap();
        assert_eq!(result["next"], json!("plugin.more"));
        assert_eq!(result["setting"], json!(true));
        assert_eq!(result["platform"], json!(std::env::consts::OS));
    }

    #[tokio::test]
    async fn never_settling_promise_returns_error_instead_of_hanging() {
        // QuickJS 没有事件循环：等不到东西的 Promise 必须报错，而不是一直挂着。
        let runtime = runtime(
            &[],
            r#"function search() { return new Promise(() => {}); }"#,
        );
        let error = runtime
            .call(Capability::Search, json!({}))
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Plugin);
        assert!(
            error.message.contains("Promise"),
            "message: {}",
            error.message
        );
    }

    #[tokio::test]
    async fn memory_hog_is_stopped_by_memory_limit() {
        // 插件疯狂分配内存：QuickJS 到达 64MB 上限后抛错，宿主不能崩。
        let runtime = runtime(
            &[],
            r#"
            function search() {
                const hoard = [];
                for (;;) { hoard.push(new Array(1024).fill("x".repeat(1024))); }
            }
        "#,
        );
        let error = runtime
            .call(Capability::Search, json!({}))
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Plugin);
        // 超时或 OOM 都算被拦住，关键是返回错误而不是进程崩溃（macOS arm64 上 QuickJS OOM 可能抛 null）。
        assert!(
            error.message.contains("超时")
                || error.message.contains("out of memory")
                || error.message.contains("内存")
                || error.message.contains("null"),
            "message: {}",
            error.message
        );
    }

    #[tokio::test]
    async fn concurrent_calls_are_serialized_and_safe() {
        let source = r#"
            async function search(params) {
                await host.storage.set("last", params.query);
                return { tracks: [], query: params.query };
            }
        "#;
        let runtime = Arc::new(runtime(&[], source));
        let first = {
            let runtime = runtime.clone();
            tokio::spawn(async move {
                runtime
                    .call(Capability::Search, json!({ "query": "a" }))
                    .await
            })
        };
        let second = {
            let runtime = runtime.clone();
            tokio::spawn(async move {
                runtime
                    .call(Capability::Search, json!({ "query": "b" }))
                    .await
            })
        };
        let first = first.await.unwrap().unwrap();
        let second = second.await.unwrap().unwrap();
        assert_eq!(first["query"], json!("a"));
        assert_eq!(second["query"], json!("b"));
    }

    #[tokio::test]
    async fn cancelled_caller_keeps_execution_gate_until_blocking_work_finishes() {
        use std::sync::atomic::AtomicUsize;
        struct SlowTransport {
            active: AtomicUsize,
            maximum: AtomicUsize,
            started: AtomicBool,
        }
        impl HttpTransport for SlowTransport {
            fn fetch(&self, _: HttpRequest) -> std::result::Result<HttpResponse, HostError> {
                let count = self.active.fetch_add(1, Ordering::SeqCst) + 1;
                self.maximum.fetch_max(count, Ordering::SeqCst);
                self.started.store(true, Ordering::SeqCst);
                std::thread::sleep(Duration::from_millis(80));
                self.active.fetch_sub(1, Ordering::SeqCst);
                Ok(HttpResponse {
                    status: 200,
                    headers: BTreeMap::new(),
                    text: "{}".into(),
                })
            }
        }
        let transport = Arc::new(SlowTransport {
            active: AtomicUsize::new(0),
            maximum: AtomicUsize::new(0),
            started: AtomicBool::new(false),
        });
        let runtime = Arc::new(runtime_with_transport(
            &["api.example.com"],
            r#"async function search() { await host.http.get("https://api.example.com/data"); return {items:[]}; }"#,
            transport.clone(),
        ));
        let task = {
            let runtime = runtime.clone();
            tokio::spawn(async move { runtime.call(Capability::Search, json!({})).await })
        };
        while !transport.started.load(Ordering::SeqCst) {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        task.abort();
        let _ = task.await;
        runtime.call(Capability::Search, json!({})).await.unwrap();
        assert_eq!(transport.maximum.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn detects_module_syntax() {
        assert!(looks_like_module("export function search() {}"));
        assert!(looks_like_module("import x from 'y';"));
        assert!(!looks_like_module("function search() {}"));
        assert!(!looks_like_module(
            "// export function x() {}\nfunction y() {}"
        ));
        assert!(!looks_like_module("/* import x */ function y() {}"));
        assert!(!looks_like_module(
            r#"const s = "export nope"; function y() {}"#
        ));
    }
}

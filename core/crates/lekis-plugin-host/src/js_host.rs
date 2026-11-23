//! 宿主 API（全局对象 `host`）的 Rust 侧实现。
//!
//! 设计：
//!
//! 1. Rust 只向 JS 暴露一组「字符串进、字符串出」的**同步**原生函数
//!    （`__lekis_http`、`__lekis_storage_set`……），它们挂在 `globalThis` 上；
//!    插件作者看到的 `host` 对象由固定的引导脚本 [`BOOTSTRAP_JS`] 在它们之上拼出来。
//!    这样 Rust 侧不必为每个 API 手写一遍 Promise / `Uint8Array` 的封送，只有一层 JSON 转换。
//! 2. 真正的网络访问走 [`HttpTransport`] trait。默认实现是 reqwest（[`ReqwestTransport`]），
//!    测试里注入 mock，不会真的发请求。
//! 3. 宿主 API 的错误带 `code` 字段（`signIn` / `setup` / `unavailable` / `unsupported` /
//!    `rateLimited`）：插件可以 `try/catch`，抛出调用之外时宿主也会把它映射回
//!    [`crate::PluginError`]。
//! 4. 设置项和插件私有存储现在只放在内存里（[`HostBridge`] 持有），进程退出即丢。
//!    以后接 SQLite / `lekis-vfs` 时把 [`HostBridge`] 里的两个 `Mutex<...>` 换成持久化后端即可，
//!    JS 侧的接口不用动。

use crate::manifest::PluginManifest;
use crate::permission::Permissions;
use rquickjs::{Ctx, Function, Object};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::sync::atomic::AtomicUsize;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

/// 引导脚本：在原生函数之上拼出插件作者看到的 `host` 对象，顺手补一个 `console`。
///
/// 它在插件源码之前执行，所以插件里可以直接写 `host.http.get(...)`。
pub const BOOTSTRAP_JS: &str = r#"
(() => {
  "use strict";
  const app = JSON.parse(globalThis.__lekis_app());

  const host = {
    native: {
      get available() { return globalThis.__lekis_native_available(); },
      async call(operation, params) {
        return JSON.parse(globalThis.__lekis_native_call(String(operation), JSON.stringify(params === undefined ? null : params)));
      },
    },
    http: {
      async request(url, options) {
        const spec = Object.assign({}, options || {}, { url: String(url) });
        const res = JSON.parse(globalThis.__lekis_http(JSON.stringify(spec)));
        const body = res.text;
        return {
          status: res.status,
          headers: res.headers || {},
          async text() { return body; },
          async json() { return JSON.parse(body); },
          async bytes() {
            const out = new Uint8Array(body.length);
            for (let i = 0; i < body.length; i += 1) {
              out[i] = body.charCodeAt(i) & 0xff;
            }
            return out;
          },
        };
      },
      get(url, options) {
        return this.request(url, Object.assign({}, options || {}, { method: "GET" }));
      },
    },
    async spawn(program, args) {
      return JSON.parse(globalThis.__lekis_spawn(String(program), JSON.stringify(args)));
    },
    setting(key, value) {
      if (arguments.length >= 2) {
        globalThis.__lekis_setting_set(String(key), JSON.stringify(value));
        return value;
      }
      const stored = globalThis.__lekis_setting_get(String(key));
      return stored === undefined ? undefined : JSON.parse(stored);
    },
    storage: {
      async get(key) {
        const value = globalThis.__lekis_storage_get(String(key));
        return value === undefined ? undefined : value;
      },
      async set(key, value) {
        globalThis.__lekis_storage_set(String(key), String(value));
      },
      async delete(key) {
        globalThis.__lekis_storage_del(String(key));
      },
      async keys() {
        return JSON.parse(globalThis.__lekis_storage_keys());
      },
    },
    t(key) {
      return globalThis.__lekis_translate(String(key));
    },
    log: {
      debug: (...args) => globalThis.__lekis_log("debug", args.map(String).join(" ")),
      info: (...args) => globalThis.__lekis_log("info", args.map(String).join(" ")),
      warn: (...args) => globalThis.__lekis_log("warn", args.map(String).join(" ")),
      error: (...args) => globalThis.__lekis_log("error", args.map(String).join(" ")),
    },
    app: { version: app.version, platform: app.platform, locale: app.locale },
  };

  Object.defineProperty(globalThis, "host", { value: host, enumerable: true });
  Object.defineProperty(globalThis, "console", {
    value: {
      log: host.log.debug,
      debug: host.log.debug,
      info: host.log.info,
      warn: host.log.warn,
      error: host.log.error,
    },
    enumerable: true,
    configurable: true,
  });

  // 插件里 `throw { code: "signIn" }` 之外，也允许 `throw new PluginError(...)`。
  class PluginError extends Error {
    constructor(code, message) {
      super(message === undefined ? String(code) : String(message));
      this.name = "PluginError";
      this.code = code;
    }
  }
  Object.defineProperty(globalThis, "PluginError", { value: PluginError, enumerable: false });
})();
"#;

/// 一次宿主 HTTP 请求（[`HostBridge`] 交给 [`HttpTransport`] 的形态）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpRequest {
    /// 完整 URL（查询串已经拼好）。
    pub url: String,
    /// HTTP 方法，全大写。
    pub method: String,
    /// 请求头。
    pub headers: BTreeMap<String, String>,
    /// 请求体（只支持文本，二进制以后再说）。
    pub body: Option<String>,
    /// 超时（毫秒），`None` 表示用传输层的默认值。
    pub timeout_ms: Option<u64>,
}

/// 一次宿主 HTTP 响应。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpResponse {
    /// 状态码。
    pub status: u16,
    /// 响应头。
    pub headers: BTreeMap<String, String>,
    /// 响应体：按 UTF-8 lossy 解码的文本（二进制内容暂不支持）。
    pub text: String,
}

/// 宿主 API 错误。`code` 就是插件看到的结构化错误码。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostError {
    /// 结构化错误码：`signIn` / `setup` / `unavailable` / `unsupported` / `rateLimited`。
    pub code: &'static str,
    /// 给开发者看的说明（会作为异常的 `message`）。
    pub message: String,
}

impl HostError {
    /// 权限不足，或者宿主没提供这个能力。
    pub fn unsupported(message: impl Into<String>) -> Self {
        Self {
            code: "unsupported",
            message: message.into(),
        }
    }

    /// 暂时不可用（网络错误、超时……）。
    pub fn unavailable(message: impl Into<String>) -> Self {
        Self {
            code: "unavailable",
            message: message.into(),
        }
    }

    /// 参数不对，或者用户还没完成设置。
    pub fn setup(message: impl Into<String>) -> Self {
        Self {
            code: "setup",
            message: message.into(),
        }
    }
}

/// HTTP 传输层。测试里注入 mock，就不会真的发请求。
pub trait HttpTransport: Send + Sync {
    /// Send exactly one HTTP hop, without automatically following redirects.
    /// [`HostBridge`] checks the permission of every redirect destination.
    fn fetch(&self, request: HttpRequest) -> std::result::Result<HttpResponse, HostError>;
}

/// 一次发给 HTTP 工作线程的任务。
struct HttpJob {
    request: HttpRequest,
    reply: std::sync::mpsc::Sender<std::result::Result<HttpResponse, HostError>>,
}

/// 真实的 HTTP 传输层（reqwest + rustls）。
///
/// 插件调用是同步 JS，不能直接 `.await` reqwest；也不方便在调用线程里临时建 tokio
/// 运行时（调用可能发生在别的运行时的工作线程上，`block_on` 会 panic）。
/// 所以这里起一个**专用工作线程**，它自己拥有一个 current-thread tokio 运行时，
/// 主线程通过 channel 同步等结果。线程在传输层被丢弃后自然退出。
pub struct ReqwestTransport {
    worker: OnceLock<std::result::Result<tokio::sync::mpsc::UnboundedSender<HttpJob>, String>>,
}

impl ReqwestTransport {
    /// 创建传输层。这里只做准备，不启动线程（第一次请求时才启动）。
    pub fn new() -> Self {
        Self {
            worker: OnceLock::new(),
        }
    }

    fn sender(
        &self,
    ) -> std::result::Result<&tokio::sync::mpsc::UnboundedSender<HttpJob>, HostError> {
        self.worker
            .get_or_init(spawn_http_worker)
            .as_ref()
            .map_err(|e| HostError::unavailable(format!("HTTP 工作线程启动失败：{e}")))
    }
}

impl Default for ReqwestTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl HttpTransport for ReqwestTransport {
    fn fetch(&self, request: HttpRequest) -> std::result::Result<HttpResponse, HostError> {
        let sender = self.sender()?;
        let (reply, answer) = std::sync::mpsc::channel();
        sender
            .send(HttpJob { request, reply })
            .map_err(|_| HostError::unavailable("HTTP 工作线程已退出（上一次请求导致它崩溃？）"))?;
        answer
            .recv()
            .map_err(|_| HostError::unavailable("HTTP 工作线程没有返回结果"))?
    }
}

/// 起 HTTP 工作线程。返回可用的发送端；初始化失败时返回错误说明。
fn spawn_http_worker() -> std::result::Result<tokio::sync::mpsc::UnboundedSender<HttpJob>, String> {
    let (jobs, mut incoming) = tokio::sync::mpsc::unbounded_channel::<HttpJob>();
    let (ready, ready_rx) = std::sync::mpsc::channel::<std::result::Result<(), String>>();
    std::thread::Builder::new()
        .name("lekis-plugin-http".to_string())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(e) => {
                    let _ = ready.send(Err(format!("创建 tokio 运行时失败：{e}")));
                    return;
                }
            };
            let client = match reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()
            {
                Ok(client) => client,
                Err(e) => {
                    let _ = ready.send(Err(format!("创建 HTTP 客户端失败：{e}")));
                    return;
                }
            };
            let _ = ready.send(Ok(()));
            // 主线程丢掉发送端之后 recv 返回 Err，线程就自然退出。
            runtime.block_on(async {
                while let Some(job) = incoming.recv().await {
                    let client = client.clone();
                    tokio::spawn(async move {
                        let result = fetch_async(&client, job.request).await;
                        let _ = job.reply.send(result);
                    });
                }
            });
        })
        .map_err(|e| format!("创建工作线程失败：{e}"))?;
    match ready_rx.recv() {
        Ok(Ok(())) => Ok(jobs),
        Ok(Err(e)) => Err(e),
        Err(_) => Err("工作线程启动后立刻退出".to_string()),
    }
}

/// 真正跑一次 HTTP 请求（在 HTTP 工作线程的运行时里）。
async fn fetch_async(
    client: &reqwest::Client,
    request: HttpRequest,
) -> std::result::Result<HttpResponse, HostError> {
    let method = reqwest::Method::from_bytes(request.method.as_bytes())
        .map_err(|e| HostError::setup(format!("不支持的 HTTP 方法 {}：{e}", request.method)))?;
    let mut builder = client.request(method, &request.url);
    builder = builder.timeout(Duration::from_millis(
        request.timeout_ms.unwrap_or(15_000).min(60_000),
    ));
    for (name, value) in &request.headers {
        builder = builder.header(name, value);
    }
    if let Some(body) = request.body {
        builder = builder.body(body);
    }

    let mut response = builder.send().await.map_err(|e| {
        let reason = if e.is_timeout() { "超时" } else { "失败" };
        HostError::unavailable(format!("请求 {} {reason}：{e}", request.url))
    })?;

    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .map(|(name, value)| {
            (
                name.as_str().to_string(),
                String::from_utf8_lossy(value.as_bytes()).to_string(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    // Plugins fetch metadata. Never buffer an unbounded media response into JS.
    const MAX_BODY: usize = 8 * 1024 * 1024;
    let mut body = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|e| HostError::unavailable(format!("读取响应体失败：{e}")))?
    {
        if body.len().saturating_add(chunk.len()) > MAX_BODY {
            return Err(HostError::unsupported(
                "HTTP response exceeds 8 MiB; use stream URLs for media",
            ));
        }
        body.extend_from_slice(&chunk);
    }
    let text = String::from_utf8_lossy(&body).into_owned();

    Ok(HttpResponse {
        status,
        headers,
        text,
    })
}

/// `host.http.request` 的参数（引导脚本 `JSON.stringify` 出来的那个对象）。
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HttpSpec {
    url: String,
    #[serde(default)]
    method: Option<String>,
    #[serde(default)]
    headers: BTreeMap<String, String>,
    #[serde(default)]
    body: Option<String>,
    #[serde(default)]
    query: BTreeMap<String, serde_json::Value>,
    #[serde(default)]
    timeout_ms: Option<u64>,
    #[serde(default)]
    redirect: Option<String>,
}

/// 插件跑起来之后仍然存在的宿主状态（设置项、私有存储、网络权限）。
///
/// 它**不属于某一次调用**：JS 上下文每次重建（或者被超时污染后重建）时，`HostBridge`
/// 由 [`crate::JsRuntime`] 一直持有，所以 `host.storage.set` 写的值在后续调用里还在。
pub struct HostBridge {
    plugin_id: String,
    native: Option<crate::native::NativeContext>,
    pub(crate) is_mygo: bool,
    pub(crate) inflight_http: AtomicUsize,
    translations: Mutex<BTreeMap<String, String>>,
    permissions: Permissions,
    transport: Arc<dyn HttpTransport>,
    /// 设置项：清单里的默认值 + 插件改过的值。以后要持久化到用户配置里。
    settings: Mutex<BTreeMap<String, serde_json::Value>>,
    /// 插件私有存储。以后要落盘（`lekis-vfs` 或单独的文件）。
    storage: Mutex<Storage>,
    /// 存储配额（字节），来自 `permissions.storage_bytes`。
    quota: u64,
}

/// 内存里的私有存储，顺带记一下已用字节数，避免每次 set 都全量重算。
#[derive(Default)]
struct Storage {
    entries: BTreeMap<String, String>,
    used: u64,
}

impl HostBridge {
    /// 由清单和权限创建宿主状态。
    pub fn new(
        manifest: &PluginManifest,
        permissions: Permissions,
        transport: Arc<dyn HttpTransport>,
    ) -> Self {
        let mut settings = BTreeMap::new();
        for spec in &manifest.settings {
            if let Some(default) = &spec.default {
                settings.insert(spec.key.clone(), default.clone());
            }
        }
        let quota = permissions.storage_bytes;
        Self {
            plugin_id: manifest.id.clone(),
            native: None,
            is_mygo: manifest.compatibility == Some(crate::manifest::Compatibility::Mygo),
            inflight_http: AtomicUsize::new(0),
            translations: Mutex::new(BTreeMap::new()),
            permissions,
            transport,
            settings: Mutex::new(settings),
            storage: Mutex::new(Storage::default()),
            quota,
        }
    }

    /// Configure manager-selected native metadata before any JS is evaluated.
    pub(crate) fn configure_native(
        &mut self,
        root: std::path::PathBuf,
        spec: Option<crate::manifest::AndroidNativeSpec>,
        granted: bool,
    ) -> lekis_types::Result<()> {
        self.native = spec
            .map(|spec| crate::native::NativeContext::new(root, spec, granted))
            .transpose()?;
        Ok(())
    }

    fn native_call(
        &self,
        operation: String,
        params: String,
    ) -> std::result::Result<String, HostError> {
        let native = self.native.as_ref().ok_or_else(|| {
            HostError::unsupported(
                "No Android native extension is configured by the plugin manager",
            )
        })?;
        let params = serde_json::from_str(&params)
            .map_err(|_| HostError::setup("Native parameters must be JSON"))?;
        let value = native.call(operation, params).map_err(|error| HostError {
            code: match error.code {
                lekis_types::ErrorCode::InvalidArgument => "setup",
                lekis_types::ErrorCode::Auth => "signIn",
                lekis_types::ErrorCode::NotFound => "unavailable",
                lekis_types::ErrorCode::Unsupported => "unsupported",
                lekis_types::ErrorCode::RateLimited => "rateLimited",
                _ => "unavailable",
            },
            message: error.message,
        })?;
        serde_json::to_string(&value).map_err(|e| HostError::unavailable(e.to_string()))
    }

    /// 插件 id（日志用）。
    pub fn plugin_id(&self) -> &str {
        &self.plugin_id
    }

    /// `host.http` 的实现：检查白名单 → 发请求 → 返回响应 JSON。
    pub(crate) fn http_json(&self, spec: &str) -> std::result::Result<String, HostError> {
        let spec: HttpSpec = serde_json::from_str(spec)
            .map_err(|e| HostError::setup(format!("host.http 的参数不是合法 JSON：{e}")))?;

        let mut url = reqwest::Url::parse(&spec.url)
            .map_err(|e| HostError::setup(format!("URL 不合法 {}：{e}", spec.url)))?;
        if !spec.query.is_empty() {
            let mut pairs = url.query_pairs_mut();
            for (key, value) in &spec.query {
                match value {
                    serde_json::Value::Null => {}
                    serde_json::Value::String(text) => {
                        pairs.append_pair(key, text);
                    }
                    other => {
                        pairs.append_pair(key, &other.to_string());
                    }
                }
            }
        }
        let mut request = HttpRequest {
            url: url.to_string(),
            method: spec
                .method
                .map(|m| m.to_ascii_uppercase())
                .unwrap_or_else(|| "GET".into()),
            headers: spec.headers,
            body: spec.body,
            timeout_ms: Some(spec.timeout_ms.unwrap_or(15_000).clamp(1, 60_000)),
        };
        let deadline =
            std::time::Instant::now() + Duration::from_millis(request.timeout_ms.unwrap_or(15_000));
        for redirect_count in 0..=8 {
            // Check every hop; transport must not automatically follow redirects.
            if !self.permissions.allows_url(&request.url) {
                return Err(HostError::unsupported(format!(
                    "插件 {} 没有访问 {} 的权限",
                    self.plugin_id, request.url
                )));
            }
            if std::time::Instant::now() >= deadline {
                return Err(HostError::unavailable("HTTP redirect deadline exceeded"));
            }
            request.timeout_ms = Some(
                u64::try_from(
                    deadline
                        .saturating_duration_since(std::time::Instant::now())
                        .as_millis(),
                )
                .unwrap_or(60_000)
                .saturating_add(1),
            );
            if request.timeout_ms == Some(0) {
                return Err(HostError::unavailable("HTTP redirect deadline exceeded"));
            }
            let response = self.transport.fetch(request.clone())?;
            let is_redirect = matches!(response.status, 301 | 302 | 303 | 307 | 308);
            let location = response
                .headers
                .iter()
                .find(|(name, _)| name.eq_ignore_ascii_case("location"))
                .map(|(_, value)| value);
            if is_redirect && spec.redirect.as_deref() == Some("error") {
                return Err(HostError::unavailable("HTTP redirect refused"));
            }
            if is_redirect && spec.redirect.as_deref() != Some("manual") {
                if let Some(location) = location {
                    if redirect_count == 8 {
                        return Err(HostError::unavailable("Too many HTTP redirects"));
                    }
                    let previous = reqwest::Url::parse(&request.url)
                        .map_err(|e| HostError::setup(e.to_string()))?;
                    let target = previous
                        .join(location)
                        .map_err(|e| HostError::setup(e.to_string()))?;
                    if previous.origin() != target.origin() {
                        // A redirect is a fresh origin: no session or plugin headers leak.
                        request.headers.clear();
                    }
                    if response.status == 303
                        || matches!(response.status, 301 | 302) && request.method == "POST"
                    {
                        request.method = "GET".into();
                        request.body = None;
                        request.headers.retain(|name, _| {
                            !name.eq_ignore_ascii_case("content-type")
                                && !name.eq_ignore_ascii_case("content-length")
                        });
                    }
                    request.url = target.to_string();
                    continue;
                }
            }
            return serde_json::to_string(&serde_json::json!({
                "url": request.url,
                "status": response.status,
                "headers": response.headers,
                "text": response.text,
            }))
            .map_err(|e| HostError::unavailable(format!("响应无法序列化：{e}")));
        }
        Err(HostError::unavailable("Too many HTTP redirects"))
    }

    /// Snapshot private storage for the application persistence layer.
    pub fn storage_snapshot(&self) -> lekis_types::Result<BTreeMap<String, String>> {
        self.storage
            .lock()
            .map(|storage| storage.entries.clone())
            .map_err(|_| {
                lekis_types::LekisError::new(
                    lekis_types::ErrorCode::Plugin,
                    "plugin storage lock poisoned",
                )
            })
    }

    /// Atomically restore private storage, enforcing the same quota as writes.
    pub fn restore_storage(&self, entries: BTreeMap<String, String>) -> lekis_types::Result<()> {
        let used = entries
            .iter()
            .try_fold(0u64, |sum, (key, value)| {
                sum.checked_add(key.len() as u64)?
                    .checked_add(value.len() as u64)
            })
            .ok_or_else(|| lekis_types::LekisError::invalid("plugin storage size overflow"))?;
        if used > self.quota {
            return Err(lekis_types::LekisError::invalid(
                "plugin storage exceeds quota",
            ));
        }
        let mut storage = self.storage.lock().map_err(|_| {
            lekis_types::LekisError::new(
                lekis_types::ErrorCode::Plugin,
                "plugin storage lock poisoned",
            )
        })?;
        *storage = Storage { entries, used };
        Ok(())
    }

    /// Supply locale text without exposing files to plugin code.
    pub fn set_translations(&self, values: BTreeMap<String, String>) -> lekis_types::Result<()> {
        *self.translations.lock().map_err(|_| {
            lekis_types::LekisError::new(
                lekis_types::ErrorCode::Plugin,
                "plugin translation lock poisoned",
            )
        })? = values;
        Ok(())
    }

    fn translate(&self, text: &str) -> String {
        self.translations
            .lock()
            .ok()
            .and_then(|values| values.get(text).cloned())
            .unwrap_or_else(|| text.into())
    }

    /// Execute a separately granted desktop program, without a shell.
    fn spawn_json(&self, program: &str, args: &str) -> std::result::Result<String, HostError> {
        if !self.permissions.allows_process(program) {
            return Err(HostError::setup(format!(
                "请先在插件权限中允许启动 {program}"
            )));
        }
        #[cfg(any(target_os = "android", target_os = "ios"))]
        {
            let _ = args;
            Err(HostError::unsupported("此平台不支持外部程序"))
        }
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        {
            let args: Vec<String> = serde_json::from_str(args)
                .map_err(|_| HostError::setup("spawn args 必须是字符串数组"))?;
            if args.len() > 128 || args.iter().map(String::len).sum::<usize>() > 65_536 {
                return Err(HostError::setup("spawn 参数过多"));
            }
            Self::run_program_blocking(program, &args)
        }
    }

    /// 跑一个外部程序并捕获输出（同步，与运行时无关）。
    ///
    /// 这里**不能**新建 Tokio 运行时再 `block_on`：调用方（QuickJS 的同步 FFI）本来就在
    /// 异步上下文里，嵌套会 panic「Cannot start a runtime from within a runtime」。
    /// 所以用纯 `std::process`：两个读取线程负责排空 stdout/stderr（只保留前 8 MiB，
    /// 但仍然读干净，避免子进程写满管道死锁），主线程用 `try_wait` 轮询 45 秒超时。
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    fn run_program_blocking(
        program: &str,
        args: &[String],
    ) -> std::result::Result<String, HostError> {
        const LIMIT: u64 = 8 * 1024 * 1024;
        const TIMEOUT: Duration = Duration::from_secs(45);

        let mut child = std::process::Command::new(program)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| HostError::setup(format!("无法启动 {program}，请安装并加入 PATH：{e}")))?;

        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| HostError::unavailable("stdout unavailable"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| HostError::unavailable("stderr unavailable"))?;
        // 超限由读取线程置标志：一旦某个管道超过 8 MiB 就**立刻**停读并关掉管口，
        // 子进程随后会因为写不出去而退出（或被下面的轮询杀掉）。不能等它自然结束
        // 再判断——那要等一个无限输出的程序跑满 45 秒。
        let overflow = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let out_flag = overflow.clone();
        let err_flag = overflow.clone();
        let out_reader = std::thread::spawn(move || Self::read_capped(stdout, LIMIT, &out_flag));
        let err_reader = std::thread::spawn(move || Self::read_capped(stderr, LIMIT, &err_flag));

        let started = std::time::Instant::now();
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) => {}
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(HostError::unavailable(error.to_string()));
                }
            }
            if overflow.load(std::sync::atomic::Ordering::Relaxed) {
                let _ = child.kill();
                let _ = child.wait();
                return Err(HostError::unavailable("外部程序输出超过 8 MiB"));
            }
            if started.elapsed() >= TIMEOUT {
                let _ = child.kill();
                let _ = child.wait();
                return Err(HostError::unavailable("外部程序运行超时（45 秒）"));
            }
            std::thread::sleep(Duration::from_millis(5));
        };

        // 进程已经退出；读取线程读到 EOF 后自然结束。
        let out = out_reader
            .join()
            .map_err(|_| HostError::unavailable("读取 stdout 的线程崩溃"))??;
        let err = err_reader
            .join()
            .map_err(|_| HostError::unavailable("读取 stderr 的线程崩溃"))??;
        if overflow.load(std::sync::atomic::Ordering::Relaxed) {
            return Err(HostError::unavailable("外部程序输出超过 8 MiB"));
        }

        Ok(serde_json::json!({
            "code": status.code().unwrap_or(-1),
            "stdout": String::from_utf8_lossy(&out),
            "stderr": String::from_utf8_lossy(&err),
        })
        .to_string())
    }

    /// 读一个管道，最多保留 `limit` 字节。
    ///
    /// 超过上限时**立刻**返回（`Drop` 掉 `reader` 会关掉管口，写端拿到 EPIPE），
    /// 并把 `overflow` 置为 `true` 交给主循环去杀进程。
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    fn read_capped(
        mut reader: impl std::io::Read,
        limit: u64,
        overflow: &std::sync::atomic::AtomicBool,
    ) -> std::result::Result<Vec<u8>, HostError> {
        let mut kept = Vec::new();
        let mut chunk = [0u8; 8192];
        loop {
            let read = reader
                .read(&mut chunk)
                .map_err(|e| HostError::unavailable(e.to_string()))?;
            if read == 0 {
                return Ok(kept);
            }
            let room = (limit as usize).saturating_sub(kept.len());
            kept.extend_from_slice(&chunk[..read.min(room)]);
            if kept.len() as u64 >= limit {
                overflow.store(true, std::sync::atomic::Ordering::Relaxed);
                return Ok(kept);
            }
        }
    }

    /// `host.setting(key)` 的读路径。
    fn setting_get(&self, key: &str) -> Option<String> {
        let settings = self.settings.lock().ok()?;
        settings
            .get(key)
            .and_then(|value| serde_json::to_string(value).ok())
    }

    /// `host.setting(key, value)` 的写路径。
    fn setting_set(&self, key: &str, json: &str) -> std::result::Result<(), HostError> {
        let value: serde_json::Value = serde_json::from_str(json)
            .map_err(|e| HostError::setup(format!("设置项 {key} 的值不是合法 JSON：{e}")))?;
        let mut settings = self
            .settings
            .lock()
            .map_err(|_| HostError::unavailable("设置项状态被污染（锁中毒）"))?;
        settings.insert(key.to_string(), value);
        Ok(())
    }

    /// `host.storage.get`。
    fn storage_get(&self, key: &str) -> Option<String> {
        let storage = self.storage.lock().ok()?;
        storage.entries.get(key).cloned()
    }

    /// `host.storage.set`：检查配额，超了报 `unsupported`。
    fn storage_set(&self, key: &str, value: &str) -> std::result::Result<(), HostError> {
        let mut storage = self
            .storage
            .lock()
            .map_err(|_| HostError::unavailable("私有存储状态被污染（锁中毒）"))?;
        let previous = storage
            .entries
            .get(key)
            .map_or(0, |v| (key.len() + v.len()) as u64);
        let used = storage
            .used
            .saturating_sub(previous)
            .saturating_add(key.len() as u64)
            .saturating_add(value.len() as u64);
        if used > self.quota {
            return Err(HostError::unsupported(format!(
                "插件 {} 的私有存储超出配额：{} + {} > {} 字节",
                self.plugin_id,
                storage.used.saturating_sub(previous),
                value.len(),
                self.quota
            )));
        }
        storage.used = used;
        storage.entries.insert(key.to_string(), value.to_string());
        Ok(())
    }

    /// `host.storage.delete`。
    fn storage_delete(&self, key: &str) {
        if let Ok(mut storage) = self.storage.lock() {
            if let Some(old) = storage.entries.remove(key) {
                storage.used = storage.used.saturating_sub((key.len() + old.len()) as u64);
            }
        }
    }

    /// `host.storage.keys` 用：返回 JSON 数组字符串。
    fn storage_keys(&self) -> String {
        let keys: Vec<String> = self
            .storage
            .lock()
            .map(|storage| storage.entries.keys().cloned().collect())
            .unwrap_or_default();
        serde_json::to_string(&keys).unwrap_or_else(|_| "[]".to_string())
    }

    /// `host.app` 用：宿主信息。
    fn app_info(&self) -> String {
        let platform = if cfg!(target_os = "windows") {
            "windows"
        } else if cfg!(target_os = "android") {
            "android"
        } else if cfg!(target_os = "macos") {
            "macos"
        } else {
            "linux"
        };
        // 语言先固定 zh-CN；以后从 App 的语言设置传进来。
        let payload = serde_json::json!({
            "version": env!("CARGO_PKG_VERSION"),
            "platform": platform,
            "locale": "zh-CN",
        });
        serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string())
    }
}

/// 把 `host` 用到的那组原生函数挂到 `globalThis` 上。
///
/// 只挂函数（`__lekis_*` 前缀），`host` 对象本身由 [`BOOTSTRAP_JS`] 拼出来。
pub fn install<'js>(ctx: &Ctx<'js>, host: &Arc<HostBridge>) -> rquickjs::Result<()> {
    let globals = ctx.globals();
    let bridge = host.clone();
    globals.set(
        "__lekis_native_available",
        Function::new(ctx.clone(), move || {
            bridge
                .native
                .as_ref()
                .is_some_and(|native| native.available())
        })?,
    )?;
    let bridge = host.clone();
    globals.set(
        "__lekis_native_call",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, operation: String, params: String| -> rquickjs::Result<String> {
                bridge
                    .native_call(operation, params)
                    .map_err(|error| throw_host_error(&ctx, error))
            },
        )?,
    )?;

    let bridge = host.clone();
    globals.set(
        "__lekis_translate",
        Function::new(ctx.clone(), move |text: String| bridge.translate(&text))?,
    )?;
    let bridge = host.clone();
    globals.set(
        "__lekis_spawn",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, program: String, args: String| -> rquickjs::Result<String> {
                bridge
                    .spawn_json(&program, &args)
                    .map_err(|e| throw_host_error(&ctx, e))
            },
        )?,
    )?;

    let bridge = host.clone();
    globals.set(
        "__lekis_http",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, spec: String| -> rquickjs::Result<String> {
                bridge
                    .http_json(&spec)
                    .map_err(|e| throw_host_error(&ctx, e))
            },
        )?,
    )?;

    let bridge = host.clone();
    globals.set(
        "__lekis_setting_get",
        Function::new(ctx.clone(), move |key: String| -> Option<String> {
            bridge.setting_get(&key)
        })?,
    )?;

    let bridge = host.clone();
    globals.set(
        "__lekis_setting_set",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, key: String, json: String| -> rquickjs::Result<()> {
                bridge
                    .setting_set(&key, &json)
                    .map_err(|e| throw_host_error(&ctx, e))
            },
        )?,
    )?;

    let bridge = host.clone();
    globals.set(
        "__lekis_storage_get",
        Function::new(ctx.clone(), move |key: String| -> Option<String> {
            bridge.storage_get(&key)
        })?,
    )?;

    let bridge = host.clone();
    globals.set(
        "__lekis_storage_set",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, key: String, value: String| -> rquickjs::Result<()> {
                bridge
                    .storage_set(&key, &value)
                    .map_err(|e| throw_host_error(&ctx, e))
            },
        )?,
    )?;

    let bridge = host.clone();
    globals.set(
        "__lekis_storage_del",
        Function::new(ctx.clone(), move |key: String| {
            bridge.storage_delete(&key);
        })?,
    )?;

    let bridge = host.clone();
    globals.set(
        "__lekis_storage_keys",
        Function::new(ctx.clone(), move || -> String { bridge.storage_keys() })?,
    )?;

    let bridge = host.clone();
    globals.set(
        "__lekis_log",
        Function::new(ctx.clone(), move |level: String, message: String| {
            bridge.log(&level, &message);
        })?,
    )?;

    let bridge = host.clone();
    globals.set(
        "__lekis_app",
        Function::new(ctx.clone(), move || -> String { bridge.app_info() })?,
    )?;

    Ok(())
}

impl HostBridge {
    /// 插件的 `host.log.*`。走 `tracing`，默认 `info` 及以上才输出。
    fn log(&self, level: &str, message: &str) {
        match level {
            "debug" => tracing::debug!(target: "plugin", plugin = %self.plugin_id, "{message}"),
            "warn" => tracing::warn!(target: "plugin", plugin = %self.plugin_id, "{message}"),
            "error" => tracing::error!(target: "plugin", plugin = %self.plugin_id, "{message}"),
            _ => tracing::info!(target: "plugin", plugin = %self.plugin_id, "{message}"),
        }
    }
}

/// 把 [`HostError`] 变成 JS 异常：抛一个带 `code` / `message` 的普通对象。
///
/// 抛普通对象（而不是 `Error` 实例）是故意的：插件 `catch (e)` 之后 `e.code` 直接可用，
/// 宿主在 Rust 侧也用同一套「读 `code` 字段」的逻辑把它映射回 [`crate::PluginError`]。
pub(crate) fn throw_host_error<'js>(ctx: &Ctx<'js>, error: HostError) -> rquickjs::Error {
    let object = match Object::new(ctx.clone()) {
        Ok(object) => object,
        Err(err) => return err,
    };
    if let Err(err) = object.set("code", error.code) {
        return err;
    }
    if let Err(err) = object.set("message", error.message.as_str()) {
        return err;
    }
    ctx.throw(object.into_value())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    /// 测试用 mock 传输层：只记录 URL，永远返回构造时给的文本。
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

    fn manifest(settings: &str, storage_kb: Option<u32>) -> PluginManifest {
        let storage = storage_kb.map_or(String::new(), |kb| format!(r#","storageKb":{kb}"#));
        let json = format!(
            r#"{{"id":"dev.lekis.test","name":"测试插件","version":"1.0.0","apiVersion":"1.0",
                "minAppVersion":"0.1.0","runtime":"js","entry":"index.js","kinds":["lyrics"],
                "settings":{settings},"permissions":{{"network":["lrclib.net","*.example.com"]{storage}}}}}"#
        );
        PluginManifest::parse(&json).unwrap()
    }

    fn bridge(transport: Arc<dyn HttpTransport>) -> HostBridge {
        let manifest = manifest("[]", None);
        let permissions = Permissions::new(&manifest.permissions, &[]);
        HostBridge::new(&manifest, permissions, transport)
    }

    #[cfg(all(unix, not(any(target_os = "android", target_os = "ios"))))]
    #[test]
    fn spawn_preserves_literal_arguments() {
        let mut manifest = manifest("[]", None);
        manifest.permissions.process = vec!["printf".into()];
        let permissions = Permissions::new(&manifest.permissions, &["printf".into()]);
        let bridge = HostBridge::new(&manifest, permissions, Arc::new(MockTransport::new("{}")));
        let result: serde_json::Value = serde_json::from_str(
            &bridge
                .spawn_json("printf", r#"["%s", "$(echo injected); *"]"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(result["stdout"], "$(echo injected); *");
        let oversized_args = serde_json::to_string(&vec!["x"; 129]).unwrap();
        assert_eq!(
            bridge
                .spawn_json("printf", &oversized_args)
                .unwrap_err()
                .code,
            "setup"
        );
    }

    #[cfg(all(unix, not(any(target_os = "android", target_os = "ios"))))]
    #[test]
    fn spawn_stops_excess_output_promptly() {
        // `yes` writes forever on every Unix and behaves the same with GNU and
        // uutils coreutils. `printf '%8388609s'` used to stand in for it, but
        // uutils rejects field widths that large instead of producing output.
        let mut manifest = manifest("[]", None);
        manifest.permissions.process = vec!["yes".into()];
        let permissions = Permissions::new(&manifest.permissions, &["yes".into()]);
        let bridge = HostBridge::new(&manifest, permissions, Arc::new(MockTransport::new("{}")));
        let start = std::time::Instant::now();
        let error = bridge.spawn_json("yes", "[]").unwrap_err();
        assert!(error.message.contains("8 MiB"), "message={}", error.message);
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "must stop at the quota, not wait for process timeout"
        );
    }

    #[test]
    fn redirect_permissions_are_checked_and_cross_origin_headers_are_dropped() {
        struct Redirects {
            calls: Mutex<Vec<HttpRequest>>,
            target: String,
        }
        impl HttpTransport for Redirects {
            fn fetch(&self, request: HttpRequest) -> std::result::Result<HttpResponse, HostError> {
                let mut calls = self.calls.lock().unwrap();
                calls.push(request);
                Ok(if calls.len() == 1 {
                    HttpResponse {
                        status: 302,
                        headers: BTreeMap::from([("Location".into(), self.target.clone())]),
                        text: String::new(),
                    }
                } else {
                    HttpResponse {
                        status: 200,
                        headers: BTreeMap::new(),
                        text: "ok".into(),
                    }
                })
            }
        }
        let transport = Arc::new(Redirects {
            calls: Mutex::new(vec![]),
            target: "https://evil.invalid/private".into(),
        });
        let bridge = super::tests::bridge(transport.clone());
        let error = bridge
            .http_json(r#"{"url":"https://lrclib.net/start","headers":{"Cookie":"secret"}}"#)
            .unwrap_err();
        assert_eq!(error.code, "unsupported");
        assert_eq!(transport.calls.lock().unwrap().len(), 1);

        let transport = Arc::new(Redirects {
            calls: Mutex::new(vec![]),
            target: "https://cdn.example.com/audio".into(),
        });
        let bridge = super::tests::bridge(transport.clone());
        let result: serde_json::Value = serde_json::from_str(&bridge.http_json(r#"{"url":"https://lrclib.net/start","headers":{"Cookie":"secret","Referer":"secret-referrer"}}"#).unwrap()).unwrap();
        assert_eq!(result["url"], "https://cdn.example.com/audio");
        assert!(transport.calls.lock().unwrap()[1].headers.is_empty());

        let transport = Arc::new(Redirects {
            calls: Mutex::new(vec![]),
            target: "https://evil.invalid/private".into(),
        });
        let bridge = super::tests::bridge(transport.clone());
        let result: serde_json::Value = serde_json::from_str(
            &bridge
                .http_json(r#"{"url":"https://lrclib.net/start","redirect":"manual"}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(result["status"], 302);
        assert_eq!(
            result["headers"]["Location"],
            "https://evil.invalid/private"
        );
        assert_eq!(transport.calls.lock().unwrap().len(), 1);
    }

    #[test]
    fn restore_storage_is_atomic_and_includes_keys_in_quota() {
        let manifest = manifest("[]", Some(1));
        let permissions = Permissions::new(&manifest.permissions, &[]);
        let bridge = HostBridge::new(&manifest, permissions, Arc::new(MockTransport::new("{}")));
        bridge.storage_set("a", "saved").unwrap();
        let old = bridge.storage_snapshot().unwrap();
        assert!(bridge
            .restore_storage(BTreeMap::from([("k".repeat(1025), String::new())]))
            .is_err());
        assert_eq!(bridge.storage_snapshot().unwrap(), old);
        bridge
            .restore_storage(BTreeMap::from([("restored".into(), "value".into())]))
            .unwrap();
        assert_eq!(bridge.storage_get("restored").as_deref(), Some("value"));
        assert!(bridge.storage_get("a").is_none());
    }

    #[test]
    fn rejects_urls_outside_whitelist() {
        let transport = Arc::new(MockTransport::new("{}"));
        let bridge = bridge(transport.clone());
        // 白名单里只有 lrclib.net 和 *.example.com。
        let spec = r#"{"url":"https://evil.invalid/x","method":"GET"}"#;
        let error = bridge.http_json(spec).unwrap_err();
        assert_eq!(error.code, "unsupported");
        assert!(transport.calls().is_empty(), "不该真的发请求");
    }

    #[test]
    fn allows_whitelisted_urls_and_builds_query() {
        let transport = Arc::new(MockTransport::new(r#"{"ok":true}"#));
        let bridge = bridge(transport.clone());
        let spec = r#"{"url":"https://lrclib.net/api/get?x=1","method":"post",
            "query":{"track_name":"晴天","limit":3,"skip":null},
            "headers":{"A":"b"},"body":"payload","timeoutMs":1234}"#;
        let response: serde_json::Value =
            serde_json::from_str(&bridge.http_json(spec).unwrap()).unwrap();
        assert_eq!(response["status"], 200);
        assert_eq!(response["text"], r#"{"ok":true}"#);

        let calls = transport.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].method, "POST");
        assert_eq!(calls[0].body.as_deref(), Some("payload"));
        // Preparing/validating the request consumes part of the shared redirect budget.
        // Scheduling delays must not make this assertion depend on an exact wall-clock ms.
        assert!(calls[0]
            .timeout_ms
            .is_some_and(|ms| (1..=1234).contains(&ms)));
        assert_eq!(calls[0].headers.get("A").map(String::as_str), Some("b"));
        assert!(calls[0].url.starts_with("https://lrclib.net/api/get?x=1&"));
        assert!(calls[0].url.contains("track_name=%E6%99%B4%E5%A4%A9"));
        assert!(calls[0].url.contains("limit=3"));
        assert!(!calls[0].url.contains("skip"));
    }

    #[test]
    fn wildcard_hosts_work() {
        let transport = Arc::new(MockTransport::new("{}"));
        let bridge = bridge(transport.clone());
        let spec = r#"{"url":"https://cdn.example.com/a.jpg"}"#;
        assert!(bridge.http_json(spec).is_ok());
        assert_eq!(transport.calls().len(), 1);
    }

    #[test]
    fn rejects_plain_http_even_when_whitelisted() {
        let transport = Arc::new(MockTransport::new("{}"));
        let bridge = bridge(transport.clone());
        let spec = r#"{"url":"http://lrclib.net/api/get"}"#;
        assert_eq!(bridge.http_json(spec).unwrap_err().code, "unsupported");
        assert!(transport.calls().is_empty());
    }

    #[test]
    fn storage_enforces_quota_and_delete_frees_it() {
        let transport = Arc::new(MockTransport::new("{}"));
        let manifest = manifest("[]", Some(1));
        let permissions = Permissions::new(&manifest.permissions, &[]);
        let bridge = HostBridge::new(&manifest, permissions, transport);

        bridge.storage_set("a", "hello").unwrap();
        assert_eq!(bridge.storage_get("a").as_deref(), Some("hello"));
        assert_eq!(bridge.storage_keys(), r#"["a"]"#);

        let too_big = "x".repeat(1024 * 1024 + 1);
        let error = bridge.storage_set("b", &too_big).unwrap_err();
        assert_eq!(error.code, "unsupported");

        // 覆盖已有键时只按增量算配额。
        bridge.storage_set("a", "hello world").unwrap();
        bridge.storage_delete("a");
        assert!(bridge.storage_get("a").is_none());
        assert_eq!(bridge.storage_keys(), "[]");
        // 删掉之后配额又空出来了。
        bridge.storage_set("c", &"y".repeat(1023)).unwrap();
        assert!(bridge.storage_set(&"k".repeat(1025), "").is_err());
    }

    #[test]
    fn settings_default_from_manifest_and_override() {
        let transport = Arc::new(MockTransport::new("{}"));
        let settings =
            r#"[{"key":"preferSynced","type":"boolean","label":"优先同步歌词","default":true}]"#;
        let manifest = manifest(settings, None);
        let permissions = Permissions::new(&manifest.permissions, &[]);
        let bridge = HostBridge::new(&manifest, permissions, transport);

        assert_eq!(bridge.setting_get("preferSynced").as_deref(), Some("true"));
        bridge.setting_set("preferSynced", "false").unwrap();
        assert_eq!(bridge.setting_get("preferSynced").as_deref(), Some("false"));
        assert!(bridge.setting_get("nothing").is_none());
    }
}

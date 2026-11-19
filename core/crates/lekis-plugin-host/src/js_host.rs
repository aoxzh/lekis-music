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
      // i18n 还没接：先把键原样返回，等 locales/<语言>.json 接进来后再查表。
      return String(key);
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
    /// 发一次请求。域名白名单已经在 [`HostBridge`] 里检查过了，实现层不用再管权限。
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
    worker: OnceLock<std::result::Result<std::sync::mpsc::Sender<HttpJob>, String>>,
}

impl ReqwestTransport {
    /// 创建传输层。这里只做准备，不启动线程（第一次请求时才启动）。
    pub fn new() -> Self {
        Self {
            worker: OnceLock::new(),
        }
    }

    fn sender(&self) -> std::result::Result<&std::sync::mpsc::Sender<HttpJob>, HostError> {
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
fn spawn_http_worker() -> std::result::Result<std::sync::mpsc::Sender<HttpJob>, String> {
    let (jobs, incoming) = std::sync::mpsc::channel::<HttpJob>();
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
            let client = match reqwest::Client::builder().build() {
                Ok(client) => client,
                Err(e) => {
                    let _ = ready.send(Err(format!("创建 HTTP 客户端失败：{e}")));
                    return;
                }
            };
            let _ = ready.send(Ok(()));
            // 主线程丢掉发送端之后 recv 返回 Err，线程就自然退出。
            while let Ok(job) = incoming.recv() {
                let result = runtime.block_on(fetch_async(&client, job.request));
                let _ = job.reply.send(result);
            }
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

    let response = builder.send().await.map_err(|e| {
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
    let text = response
        .text()
        .await
        .map_err(|e| HostError::unavailable(format!("读取 {} 的响应体失败：{e}", request.url)))?;

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
}

/// 插件跑起来之后仍然存在的宿主状态（设置项、私有存储、网络权限）。
///
/// 它**不属于某一次调用**：JS 上下文每次重建（或者被超时污染后重建）时，`HostBridge`
/// 由 [`crate::JsRuntime`] 一直持有，所以 `host.storage.set` 写的值在后续调用里还在。
pub struct HostBridge {
    plugin_id: String,
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
            permissions,
            transport,
            settings: Mutex::new(settings),
            storage: Mutex::new(Storage::default()),
            quota,
        }
    }

    /// 插件 id（日志用）。
    pub fn plugin_id(&self) -> &str {
        &self.plugin_id
    }

    /// `host.http` 的实现：检查白名单 → 发请求 → 返回响应 JSON。
    fn http_json(&self, spec: &str) -> std::result::Result<String, HostError> {
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
        let url = url.to_string();

        // 白名单检查必须真的做，而且要在网络访问之前做。
        if !self.permissions.allows_url(&url) {
            return Err(HostError::unsupported(format!(
                "插件 {} 没有访问 {url} 的权限：请在 plugin.json 的 permissions.network 里声明该域名，\
                 并且只能用 https（http 只允许 localhost）",
                self.plugin_id
            )));
        }

        let request = HttpRequest {
            url: url.clone(),
            method: spec
                .method
                .map(|m| m.to_ascii_uppercase())
                .unwrap_or_else(|| "GET".to_string()),
            headers: spec.headers,
            body: spec.body,
            timeout_ms: Some(spec.timeout_ms.unwrap_or(15_000)),
        };
        tracing::debug!(
            target: "plugin",
            plugin = %self.plugin_id,
            %url,
            method = %request.method,
            "host.http"
        );

        let response = self.transport.fetch(request)?;
        let payload = serde_json::json!({
            "status": response.status,
            "headers": response.headers,
            "text": response.text,
        });
        serde_json::to_string(&payload)
            .map_err(|e| HostError::unavailable(format!("响应无法序列化：{e}")))
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
        let previous = storage.entries.get(key).map_or(0, |v| v.len() as u64);
        let used = storage.used.saturating_sub(previous) + value.len() as u64;
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
                storage.used = storage.used.saturating_sub(old.len() as u64);
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
fn throw_host_error<'js>(ctx: &Ctx<'js>, error: HostError) -> rquickjs::Error {
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
        assert_eq!(calls[0].timeout_ms, Some(1234));
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
        bridge.storage_set("c", &"y".repeat(1024)).unwrap();
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

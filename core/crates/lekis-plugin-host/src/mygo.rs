//! Independent adapter for the public MyGO plugin README contract.
//!
//! MyGO application code is AGPL and is deliberately not included. This module
//! implements only the documented stream source subset; unsupported UI/process
//! contracts fail with a structured error.
use crate::js_host::{HostBridge, HostError};
use md5::{Digest, Md5};
use rquickjs::function::Opt;
use rquickjs::{Ctx, Function};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

pub(crate) const BOOTSTRAP: &str = include_str!("mygo_host.js");
pub(crate) const ADAPTER: &str = include_str!("mygo_adapter.js");

type Pending = Arc<Mutex<BTreeMap<u32, Option<String>>>>;

/// Install per-context request queues. At most eight requests can be in flight
/// across all contexts for a plugin, including requests whose JS was aborted.
pub(crate) fn install<'js>(ctx: &Ctx<'js>, host: &Arc<HostBridge>) -> rquickjs::Result<()> {
    let globals = ctx.globals();
    globals.set(
        "__mygo_md5",
        Function::new(ctx.clone(), |text: String| {
            format!("{:x}", Md5::digest(text.as_bytes()))
        })?,
    )?;
    globals.set("__mygo_url", Function::new(ctx.clone(), |ctx: Ctx<'js>, input: String, base: Opt<Option<String>>| -> rquickjs::Result<String> {
        let result = match base.0.flatten() {
            Some(base) => reqwest::Url::parse(&base).and_then(|base| base.join(&input)),
            None => reqwest::Url::parse(&input),
        };
        let url = result.map_err(|e| crate::js_host::throw_host_error(&ctx, HostError::setup(e.to_string())))?;
        let host = url.host_str().unwrap_or("");
        let authority = match url.port() { Some(port) => format!("{host}:{port}"), None => host.to_string() };
        Ok(serde_json::json!({"href":url.as_str(),"origin":url.origin().ascii_serialization(),
            "protocol":format!("{}:",url.scheme()),"host":authority,"hostname":host,
            "port":url.port().map(|p|p.to_string()).unwrap_or_default(),"pathname":url.path(),
            "search":url.query().map(|q|format!("?{q}")).unwrap_or_default(),
            "hash":url.fragment().map(|f|format!("#{f}")).unwrap_or_default(),
            "username":url.username(),"password":url.password().unwrap_or("")}).to_string())
    })?)?;

    let pending: Pending = Arc::new(Mutex::new(BTreeMap::new()));
    let sequence = AtomicU32::new(1);
    let bridge = host.clone();
    let requests = pending.clone();
    globals.set("__mygo_fetch_start", Function::new(ctx.clone(), move |ctx: Ctx<'js>, spec: String| -> rquickjs::Result<u32> {
        if requests.lock().map_or(true, |requests| requests.len() >= 8) {
            return Err(crate::js_host::throw_host_error(&ctx, HostError::unsupported("At most eight unconsumed plugin fetches may be retained")));
        }
        let mut count = bridge.inflight_http.load(Ordering::SeqCst);
        let acquired = loop {
            if count >= 8 { break false; }
            match bridge.inflight_http.compare_exchange_weak(count, count + 1, Ordering::SeqCst, Ordering::SeqCst) {
                Ok(_) => break true,
                Err(current) => count = current,
            }
        };
        if !acquired {
            return Err(crate::js_host::throw_host_error(&ctx, HostError::unsupported("At most eight plugin fetches may run concurrently")));
        }
        let id = sequence.fetch_add(1, Ordering::Relaxed);
        match requests.lock() {
            Ok(mut requests) => { requests.insert(id, None); }
            Err(_) => {
                bridge.inflight_http.fetch_sub(1, Ordering::SeqCst);
                return Err(crate::js_host::throw_host_error(&ctx, HostError::unavailable("Fetch queue lock poisoned")));
            }
        }
        let bridge = bridge.clone();
        let requests = requests.clone();
        let rollback_bridge = bridge.clone();
        let rollback_requests = requests.clone();
        let spawned = std::thread::Builder::new().name("lekis-mygo-fetch".into()).spawn(move || {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| bridge.http_json(&spec)))
                .unwrap_or_else(|_| Err(HostError::unavailable("HTTP transport panicked")));
            let payload = match result {
                Ok(value) => serde_json::json!({"result":value}),
                Err(error) => serde_json::json!({"error":{"code":error.code,"message":error.message}}),
            }.to_string();
            if let Ok(mut requests) = requests.lock() {
                if let Some(slot) = requests.get_mut(&id) { *slot = Some(payload); }
            }
            bridge.inflight_http.fetch_sub(1, Ordering::SeqCst);
        });
        if let Err(error) = spawned {
            rollback_bridge.inflight_http.fetch_sub(1, Ordering::SeqCst);
            if let Ok(mut requests) = rollback_requests.lock() { requests.remove(&id); }
            return Err(crate::js_host::throw_host_error(&ctx, HostError::unavailable(error.to_string())));
        }
        Ok(id)
    })?)?;
    let requests = pending.clone();
    globals.set(
        "__mygo_fetch_poll",
        Function::new(ctx.clone(), move |id: u32| -> Option<String> {
            let mut requests = requests.lock().ok()?;
            if requests.get(&id)?.is_some() {
                requests.remove(&id).flatten()
            } else {
                None
            }
        })?,
    )?;
    globals.set(
        "__mygo_fetch_forget",
        Function::new(ctx.clone(), move |id: u32| {
            if let Ok(mut requests) = pending.lock() {
                requests.remove(&id);
            }
        })?,
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
    use super::*;
    use crate::{
        Capability, HttpRequest, HttpResponse, HttpTransport, JsRuntime, Permissions,
        PluginManifest, PluginRuntime,
    };
    use serde_json::json;
    use std::time::{Duration, Instant};

    struct Transport {
        delay: Duration,
    }
    impl HttpTransport for Transport {
        fn fetch(&self, _: HttpRequest) -> Result<HttpResponse, HostError> {
            std::thread::sleep(self.delay);
            Ok(HttpResponse {
                status: 200,
                headers: BTreeMap::from([("X-Example".into(), "yes".into())]),
                text: r#"{"ok":true}"#.into(),
            })
        }
    }
    fn load(source: &str, delay: Duration) -> JsRuntime {
        let manifest = PluginManifest::parse(r#"{"id":"example","name":"Example","version":"1.0.0","main":"index.js","permissions":{"network":["api.example.com"]},"settings":[{"key":"flag","type":"boolean","label":"Flag","default":true}]}"#).unwrap();
        let permissions = Permissions::new(&manifest.permissions, &[]);
        JsRuntime::load_with_transport(manifest, permissions, source, Arc::new(Transport { delay }))
            .unwrap()
    }

    #[tokio::test]
    async fn structured_lyrics_preserve_words_and_translation_for_review() {
        let runtime = load(
            r#"export function lyrics() { return {lines:[{start:1450, words:[{start:1450,text:"青"},{start:1600,text:"空"}], translation:"蓝天"}]}; }"#,
            Duration::ZERO,
        );
        let result = runtime
            .call(Capability::Lyrics, json!({"id":"x"}))
            .await
            .unwrap();
        assert_eq!(result["format"], "enhanced_lrc");
        assert_eq!(
            result["content"],
            "[00:01.450]<00:01.450>青<00:01.600>空\n[00:01.450]蓝天"
        );
        assert_eq!(result["confidence"], 0.8);
    }

    #[tokio::test]
    async fn public_contract_maps_metadata_pagination_quality_and_storage() {
        let source = r#"
            export function search({query,kind,offset}) {
                if (kind !== "tracks" || offset !== 2 || host.setting("flag") !== "true") throw Error("wrong inputs");
                const old = host.storage.get("object") || {count:0};
                old.count++; host.storage.set("object",old);
                const standalone = new URL("https://api.example.com/single?deadline=2000000000");
                if (standalone.hostname !== "api.example.com" || standalone.searchParams.get("deadline") !== "2000000000") throw Error("wrong standalone URL");
                const explicitUndefined = new URL("https://api.example.com/undefined", undefined);
                if (explicitUndefined.hostname !== "api.example.com") throw Error("wrong undefined base");
                const url = new URL("../track?a=b", "https://api.example.com/a/");
                url.searchParams.set("q", "one two");
                if (url.hostname !== "api.example.com" || !url.href.includes("q=one+two")) throw Error("wrong URL");
                const name = host.t(query) + old.count + host.crypto.md5("abc");
                return {tracks:[{id:"one",name,artists:[{id:"a",name:"Artist"}],album:{name:"Album",imageUrl:"https://api.example.com/{size}.jpg"},duration:1234}],more:true};
            }
            export function stream({id,quality}) { return {url:`https://api.example.com/${id}/${quality}`,type:"m4a",headers:{Referer:"https://api.example.com/"}}; }
        "#;
        let runtime = load(source, Duration::ZERO);
        runtime
            .set_translations(BTreeMap::from([("Name".into(), "Translated".into())]))
            .unwrap();
        let params = json!({"query":"Name","type":"track","cursor":"2"});
        let result = runtime
            .call(Capability::Search, params.clone())
            .await
            .unwrap();
        assert_eq!(result["next"], "3");
        assert_eq!(
            result["items"][0]["title"],
            "Translated1900150983cd24fb0d6963f7d28e17f72"
        );
        assert_eq!(result["items"][0]["artists"], json!(["Artist"]));
        assert_eq!(
            result["items"][0]["artworkUrl"],
            "https://api.example.com/600.jpg"
        );
        assert_eq!(result["items"][0]["durationMs"], 1234);
        let restored = load(source, Duration::ZERO);
        restored
            .restore_storage(runtime.storage_snapshot().unwrap())
            .unwrap();
        let second = restored.call(Capability::Search, params).await.unwrap();
        assert!(second["items"][0]["title"]
            .as_str()
            .unwrap()
            .starts_with("Name2"));
        let result = runtime
            .call(Capability::Stream, json!({"id":"one","quality":"normal"}))
            .await
            .unwrap();
        assert_eq!(result["url"], "https://api.example.com/one/standard");
        assert_eq!(result["mimeType"], "audio/mp4");
        assert!(!runtime.capabilities().contains(&Capability::Browse));
    }

    #[tokio::test]
    async fn browse_flattens_public_sections_without_losing_source_ids() {
        let runtime = load(
            r#"
            export function home() { return {sections:[{tracks:[{id:"t",name:"Track",artists:[{name:"A"}]}],links:[{page:"charts",title:"Charts"}],albums:[{id:"a",name:"Album"}]}]}; }
            export function browse({page}) { return {sections:[{tracks:[{id:page,name:"Page track"}]}]}; }
            export function album({id}) { return {album:{id,name:"Album"},tracks:[{id:"album-track",name:"Song"}]}; }
        "#,
            Duration::ZERO,
        );
        let root = runtime
            .call(Capability::Browse, json!({"path":""}))
            .await
            .unwrap();
        assert_eq!(root["items"][0]["id"], "t");
        assert_eq!(root["items"][1]["id"], "album:a");
        assert_eq!(root["items"][2]["id"], "page:charts");
        assert_eq!(
            runtime
                .call(Capability::Browse, json!({"path":"page:charts"}))
                .await
                .unwrap()["items"][0]["id"],
            "charts"
        );
        assert_eq!(
            runtime
                .call(Capability::Browse, json!({"path":"album:a"}))
                .await
                .unwrap()["items"][0]["id"],
            "album-track"
        );
        assert_eq!(
            runtime
                .call(Capability::Browse, json!({"path":"playlist:absent"}))
                .await
                .unwrap_err()
                .code,
            lekis_types::ErrorCode::Unsupported
        );
    }

    #[tokio::test]
    async fn fetch_headers_timers_and_abort_are_driven_by_host_event_loop() {
        let runtime = load(
            r#"
            export async function search() {
                await new Promise(resolve => setTimeout(resolve, 5));
                const response = await fetch("https://api.example.com/data");
                if (!response.ok || response.headers.get("x-example") !== "yes" || !(await response.json()).ok) throw Error("bad fetch");
                return {tracks:[{id:"ok",name:response.url}]};
            }
        "#,
            Duration::from_millis(10),
        );
        let result = runtime
            .call(Capability::Search, json!({"query":"x"}))
            .await
            .unwrap();
        assert_eq!(result["items"][0]["title"], "https://api.example.com/data");
        let runtime = load(
            r#"
            export async function search() {
                const controller = new AbortController();
                const timer = setTimeout(() => controller.abort(), 10);
                try { await fetch("https://api.example.com/slow",{signal:controller.signal}); throw Error("not aborted"); }
                catch(error) { if (error.name !== "AbortError") throw error; }
                finally { clearTimeout(timer); }
                return {tracks:[{id:"aborted",name:"Aborted"}]};
            }
        "#,
            Duration::from_millis(200),
        );
        let start = Instant::now();
        let result = runtime
            .call(Capability::Search, json!({"query":"x"}))
            .await
            .unwrap();
        assert_eq!(result["items"][0]["id"], "aborted");
        assert!(start.elapsed() < Duration::from_millis(150));
    }

    #[tokio::test]
    async fn unsafe_or_unavailable_host_contracts_fail_explicitly() {
        let runtime = load(
            "export function stream() { return host.spawn('ffmpeg',[]); }",
            Duration::ZERO,
        );
        assert_eq!(
            runtime
                .call(Capability::Stream, json!({"id":"x"}))
                .await
                .unwrap_err()
                .code,
            lekis_types::ErrorCode::Unsupported
        );
        let runtime = load("export async function search() { await fetch('https://evil.invalid/'); return {tracks:[]}; }", Duration::ZERO);
        assert_eq!(
            runtime
                .call(Capability::Search, json!({"query":"x"}))
                .await
                .unwrap_err()
                .code,
            lekis_types::ErrorCode::Unsupported
        );
        let mut runtime = load("export async function search() { await new Promise(resolve => setTimeout(resolve, 10000)); return {tracks:[]}; }", Duration::ZERO);
        runtime.set_call_timeout(Duration::from_millis(50));
        let start = Instant::now();
        assert!(runtime
            .call(Capability::Search, json!({"query":"x"}))
            .await
            .is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
    }
}

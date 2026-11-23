// Clean-room implementation of documented MyGO host contracts.
(() => {
  "use strict";
  const unsupported = name => { throw new PluginError("unsupported", `MyGO ${name} is not supported by Lekis`); };
  host.platform = host.app.platform === "macos" ? "darwin" : host.app.platform;
  host.arch = globalThis.__mygo_arch;
  host.language = () => host.app.locale;
  host.spawn = () => unsupported("background process handles");
  for (const name of ["dir", "dataDir"]) Object.defineProperty(host, name, { get: () => unsupported("filesystem paths") });
  for (const name of ["openURL", "signInPrompt", "waitForRedirect", "webSignIn", "removeDataDir"]) host[name] = () => unsupported(name);
  host.storage = {
    get(key) {
      const value = __lekis_storage_get(String(key));
      return value === undefined ? null : JSON.parse(value);
    },
    set(key, value) { __lekis_storage_set(String(key), JSON.stringify(value)); },
    remove(key) { __lekis_storage_del(String(key)); },
  };
  host.crypto = { md5: text => __mygo_md5(String(text)), aesEcbEncrypt: () => unsupported("AES-ECB") };
  const nativeSetting = host.setting;
  host.setting = key => {
    const value = nativeSetting(key);
    return value === undefined || value === null ? "" : String(value);
  };

  class Headers {
    constructor(init) {
      this._values = new Map();
      if (init instanceof Headers || Array.isArray(init)) for (const [key, value] of init) this.append(key, value);
      else for (const [key, value] of Object.entries(init || {})) this.set(key, value);
    }
    set(key, value) { this._values.set(String(key).toLowerCase(), String(value)); }
    append(key, value) { key = String(key).toLowerCase(); this.set(key, this.has(key) ? `${this.get(key)}, ${value}` : value); }
    get(key) { return this._values.get(String(key).toLowerCase()) ?? null; }
    has(key) { return this._values.has(String(key).toLowerCase()); }
    delete(key) { this._values.delete(String(key).toLowerCase()); }
    entries() { return this._values.entries(); }
    keys() { return this._values.keys(); }
    values() { return this._values.values(); }
    forEach(callback, receiver) { for (const [key, value] of this) callback.call(receiver, value, key, this); }
    [Symbol.iterator]() { return this.entries(); }
  }
  class URLSearchParams {
    constructor(input = "") {
      this._pairs = [];
      if (typeof input === "string") {
        const decode = text => decodeURIComponent(text.replace(/\+/g, " "));
        for (const entry of input.replace(/^\?/, "").split("&")) if (entry) {
          const at = entry.indexOf("=");
          this.append(decode(at < 0 ? entry : entry.slice(0, at)), decode(at < 0 ? "" : entry.slice(at + 1)));
        }
      } else for (const [key, value] of input && typeof input[Symbol.iterator] === "function" ? input : Object.entries(input)) this.append(key, value);
    }
    append(key, value) { this._pairs.push([String(key), String(value)]); this._change?.(); }
    set(key, value) { key = String(key); const at = this._pairs.findIndex(p => p[0] === key); this._pairs = this._pairs.filter(p => p[0] !== key); this._pairs.splice(at < 0 ? this._pairs.length : at, 0, [key, String(value)]); this._change?.(); }
    get(key) { return this._pairs.find(p => p[0] === String(key))?.[1] ?? null; }
    getAll(key) { return this._pairs.filter(p => p[0] === String(key)).map(p => p[1]); }
    has(key) { return this._pairs.some(p => p[0] === String(key)); }
    delete(key) { this._pairs = this._pairs.filter(p => p[0] !== String(key)); this._change?.(); }
    sort() { this._pairs.sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0); this._change?.(); }
    toString() { const encode = value => encodeURIComponent(value).replace(/%20/g, "+").replace(/[!'()~]/g, c => `%${c.charCodeAt(0).toString(16).toUpperCase()}`); return this._pairs.map(([k,v]) => `${encode(k)}=${encode(v)}`).join("&"); }
    entries() { return this._pairs[Symbol.iterator](); }
    keys() { return this._pairs.map(p => p[0])[Symbol.iterator](); }
    values() { return this._pairs.map(p => p[1])[Symbol.iterator](); }
    forEach(callback, receiver) { for (const [key, value] of this) callback.call(receiver, value, key, this); }
    [Symbol.iterator]() { return this.entries(); }
  }
  class URL {
    constructor(input, base) {
      this._parts = JSON.parse(__mygo_url(String(input), base === undefined ? undefined : String(base)));
      this._params = new URLSearchParams(this._parts.search);
      this._params._change = () => { this.search = this._params.toString(); };
    }
    get href() { return this._parts.href; }
    set href(value) { this._parts = JSON.parse(__mygo_url(String(value))); this._params = new URLSearchParams(this._parts.search); this._params._change = () => { this.search = this._params.toString(); }; }
    get searchParams() { return this._params; }
    get search() { return this._parts.search; }
    set search(value) {
      value = String(value).replace(/^\?/, "");
      const old = this._parts; this._parts = JSON.parse(__mygo_url(old.href.split(/[?#]/)[0] + (value ? `?${value}` : "") + old.hash));
      this._params._pairs = new URLSearchParams(value)._pairs;
    }
    toString() { return this.href; }
    toJSON() { return this.href; }
  }
  for (const key of ["origin", "protocol", "host", "hostname", "port", "pathname", "hash", "username", "password"]) Object.defineProperty(URL.prototype, key, { get() { return this._parts[key]; }, set() { unsupported(`URL.${key} mutation`); } });

  class AbortSignal {
    constructor() { this.aborted = false; this.reason = undefined; this._listeners = new Set(); }
    addEventListener(type, callback) { if (type === "abort") this._listeners.add(callback); }
    removeEventListener(type, callback) { if (type === "abort") this._listeners.delete(callback); }
    throwIfAborted() { if (this.aborted) throw this.reason; }
  }
  class AbortController {
    constructor() { this.signal = new AbortSignal(); }
    abort(reason) {
      if (this.signal.aborted) return;
      this.signal.aborted = true;
      this.signal.reason = reason ?? Object.assign(new Error("The operation was aborted"), { name: "AbortError" });
      for (const callback of this.signal._listeners) callback.call(this.signal, { type: "abort", target: this.signal });
      this.signal.onabort?.({ type: "abort", target: this.signal });
    }
  }
  const timers = new Map(), requests = new Map();
  let nextTimer = 1;
  globalThis.setTimeout = (callback, delay = 0, ...args) => {
    if (typeof callback !== "function") throw new TypeError("Timer callback must be a function");
    if (timers.size >= 256) unsupported("more than 256 pending timers");
    const id = nextTimer++; timers.set(id, { at: Date.now() + Math.max(0, Number(delay) || 0), callback, args }); return id;
  };
  globalThis.clearTimeout = id => { timers.delete(id); };
  globalThis.setInterval = () => unsupported("interval timers");
  globalThis.clearInterval = globalThis.clearTimeout;
  globalThis.fetch = (input, options = {}) => new Promise((resolve, reject) => {
    if (options.signal?.aborted) { reject(options.signal.reason); return; }
    if (options.body !== undefined && typeof options.body !== "string") { reject(new PluginError("unsupported", "Only text fetch bodies are supported")); return; }
    const id = __mygo_fetch_start(JSON.stringify({ url: String(input), method: options.method || "GET", headers: Object.fromEntries(new Headers(options.headers)), body: options.body, redirect: options.redirect, timeoutMs: options.timeoutMs }));
    requests.set(id, { resolve, reject, signal: options.signal });
  });
  globalThis.__mygo_pending = () => timers.size > 0 || requests.size > 0;
  globalThis.__mygo_tick = () => {
    const now = Date.now();
    for (const [id, timer] of Array.from(timers)) if (timer.at <= now && timers.has(id)) { timers.delete(id); timer.callback(...timer.args); }
    for (const [id, request] of requests) {
      if (request.signal?.aborted) { requests.delete(id); __mygo_fetch_forget(id); request.reject(request.signal.reason); continue; }
      const value = __mygo_fetch_poll(id);
      if (value === undefined) continue;
      requests.delete(id);
      const envelope = JSON.parse(value);
      if (envelope.error) { request.reject(new PluginError(envelope.error.code, envelope.error.message)); continue; }
      const response = JSON.parse(envelope.result), headers = new Headers(response.headers), body = response.text;
      request.resolve({ status: response.status, ok: response.status >= 200 && response.status < 300, url: response.url,
        headers, async text() { return body; }, async json() { return JSON.parse(body); },
        async arrayBuffer() { unsupported("binary fetch responses"); }, async blob() { unsupported("binary fetch responses"); } });
    }
  };
  Object.assign(globalThis, { Headers, URLSearchParams, URL, AbortController, AbortSignal });
})();

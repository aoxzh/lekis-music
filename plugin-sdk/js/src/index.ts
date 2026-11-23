/**
 * Lekis 插件 SDK —— 插件 API 1.2。
 *
 * 插件就是一个 ES 模块：每个能力导出一个同名函数，参数是一个对象，返回 Promise。
 * 没导出的能力就是不支持。宿主通过全局对象 `host` 提供有限的能力（见 {@link Host}）。
 *
 * 这个文件只有类型，没有运行时代码；插件不需要打包它。
 */

// ---------------------------------------------------------------------------
// 通用类型
// ---------------------------------------------------------------------------

/** 宿主告诉插件"我要找的是哪首歌"。 */
export interface TrackHint {
  title: string;
  artists: string[];
  album?: string;
  /** 毫秒。 */
  durationMs?: number;
  mbidRecording?: string;
}

/** 插件返回的一首歌。`id` 由插件自己定义，宿主原样保存，之后调用 `stream` 时传回来。 */
export interface PluginTrack {
  id: string;
  title: string;
  artists: string[];
  album?: string;
  durationMs?: number;
  artworkUrl?: string;
  /** 是否需要登录才能播放（界面会显示锁形图标）。 */
  requiresSignIn?: boolean;
}

export interface PluginAlbum {
  id: string;
  title: string;
  artists: string[];
  year?: number;
  artworkUrl?: string;
}

export interface PluginArtist {
  id: string;
  name: string;
  imageUrl?: string;
}

export interface PluginPlaylist {
  id: string;
  title: string;
  description?: string;
  artworkUrl?: string;
  tracks: PluginTrack[];
}

export interface Page<T> {
  items: T[];
  /** 下一页的游标；没有下一页时为空。 */
  next?: string;
}

/** 结构化错误码。App 据此引导用户（去登录、去设置、稍后再试……）。 */
export type PluginErrorCode = "signIn" | "setup" | "unavailable" | "unsupported" | "rateLimited";

/** 插件出错时抛出这个，而不是普通 Error。 */
export class PluginError extends Error {
  constructor(public readonly code: PluginErrorCode, message?: string) {
    super(message ?? code);
  }
}

// ---------------------------------------------------------------------------
// 能力（插件导出的函数）
// ---------------------------------------------------------------------------

export interface SearchParams {
  query: string;
  type: "track" | "album" | "artist" | "playlist";
  cursor?: string;
  /** 宿主请求的最大条目数（API 1.1，可选；宿主仍会截断超出部分）。 */
  limit?: number;
}
export type SearchResult = Page<PluginTrack | PluginAlbum | PluginArtist | PluginPlaylist>;

export interface BrowseParams {
  /** 空字符串表示根目录；之后的路径由插件自己定义。 */
  path: string;
  cursor?: string;
}
export interface BrowseEntry {
  kind: "folder" | "track" | "album" | "playlist";
  id: string;
  title: string;
  subtitle?: string;
  artworkUrl?: string;
}
export type BrowseResult = Page<BrowseEntry>;

export interface StreamParams {
  id: string;
  /** 宿主的偏好，插件尽量满足。 */
  quality: "lossless" | "high" | "normal" | "low";
}
export interface StreamResult {
  url: string;
  /** 额外请求头（必须是 permissions.requestHeaders 里声明过的域名）。 */
  headers?: Record<string, string>;
  /** 地址的有效期（毫秒时间戳），过期后宿主会重新调用 stream。 */
  expiresAt?: number;
  mimeType?: string;
}

export interface LyricsParams {
  track: TrackHint;
}
export interface LyricsResult {
  format: "plain" | "lrc" | "enhanced_lrc" | "ttml";
  content: string;
  /** 翻译（同样的格式和时间轴）。 */
  translation?: string;
  /** 插件对匹配结果的把握（0~1）。宿主还会自己再打一次分。 */
  confidence?: number;
}

export interface ArtworkParams {
  track: TrackHint;
  /** 想要的最小边长（像素）。 */
  minSize?: number;
}
export interface ArtworkResult {
  url: string;
  width?: number;
  height?: number;
  confidence?: number;
}

export interface PlaylistParams {
  id: string;
}

export interface ScrobbleParams {
  track: TrackHint;
  /** 开始播放的时间（毫秒时间戳）。 */
  startedAt: number;
  playedMs: number;
  /** "nowPlaying" 表示刚开始播放，"scrobble" 表示达到了计入播放的条件。 */
  kind: "nowPlaying" | "scrobble";
}

/** 一个插件可以导出的全部能力（全部可选）。 */
export interface PluginModule {
  search?(params: SearchParams): Promise<SearchResult>;
  browse?(params: BrowseParams): Promise<BrowseResult>;
  stream?(params: StreamParams): Promise<StreamResult>;
  lyrics?(params: LyricsParams): Promise<LyricsResult | null>;
  artwork?(params: ArtworkParams): Promise<ArtworkResult | null>;
  playlist?(params: PlaylistParams): Promise<PluginPlaylist>;
  scrobble?(params: ScrobbleParams): Promise<void>;
}

// ---------------------------------------------------------------------------
// 宿主 API（全局对象 `host`）
// ---------------------------------------------------------------------------

export interface HttpRequestOptions {
  method?: "GET" | "POST" | "PUT" | "DELETE" | "PATCH" | "HEAD";
  query?: Record<string, string | number | boolean | undefined>;
  headers?: Record<string, string>;
  body?: string | Uint8Array;
  /** 默认 15000。 */
  timeoutMs?: number;
}

export interface HttpResponse {
  status: number;
  headers: Record<string, string>;
  text(): Promise<string>;
  json<T = unknown>(): Promise<T>;
  bytes(): Promise<Uint8Array>;
}

export interface Host {
  /** API 1.2: optional Android DEX extension. Runs with full app privileges and
   * requires a separate user grant; false on desktop/iOS or absent executor. */
  native: {
    readonly available: boolean;
    /** The manager selects the manifest entry/class. JS cannot select a path. */
    call<T = unknown>(operation: string, params?: unknown): Promise<T>;
  };
  /** HTTP 请求。只能访问 permissions.network 里声明的域名，而且只能用 HTTPS。 */
  http: {
    request(url: string, options?: HttpRequestOptions): Promise<HttpResponse>;
    get(url: string, options?: Omit<HttpRequestOptions, "method">): Promise<HttpResponse>;
  };
  /** 读取设置项。 */
  setting<T = unknown>(key: string): T | undefined;
  /** 插件私有存储（有配额，默认 1MB）。 */
  storage: {
    get(key: string): Promise<string | undefined>;
    set(key: string, value: string): Promise<void>;
    delete(key: string): Promise<void>;
  };
  /** 多语言文字（从 locales/<语言>.json 读取）。 */
  t(key: string, vars?: Record<string, string | number>): string;
  /** 哈希、HMAC、随机数等常用加密函数。 */
  crypto: {
    md5(input: string): string;
    sha256(input: string | Uint8Array): string;
    hmacSha256(key: string | Uint8Array, data: string | Uint8Array): string;
    randomHex(bytes: number): string;
  };
  /** 用系统浏览器打开链接。 */
  openURL(url: string): Promise<void>;
  /**
   * 网页登录：打开登录页，用户登录后返回 Cookie（或者回调地址里的参数）。
   * 需要 permissions.webSignIn = true。用于用户登录**自己的**账号。
   */
  webSignIn(options: { url: string; finishUrlPrefix: string }): Promise<{
    cookies: Record<string, string>;
    finishUrl: string;
  }>;
  /**
   * 启动外部程序（只在桌面端可用），程序名必须在 permissions.process 里声明，并且用户在设置里允许过。
   * 不经过 shell；单次超时 45 秒；stdout / stderr 各最多 8 MiB。
   * 外部程序以当前用户身份运行，不受宿主 HTTP 域名白名单约束。
   */
  spawn?(program: string, args: string[]): Promise<{ code: number; stdout: string; stderr: string }>;
  log: {
    debug(...args: unknown[]): void;
    info(...args: unknown[]): void;
    warn(...args: unknown[]): void;
    error(...args: unknown[]): void;
  };
  /** 宿主信息。 */
  readonly app: {
    version: string;
    platform: "android" | "windows" | "linux" | "ios" | "macos";
    locale: string;
  };
}

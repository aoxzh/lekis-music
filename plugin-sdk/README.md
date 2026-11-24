# Lekis 插件 SDK

对外开放的插件协议。设计见 [REQUIREMENTS 3.11](../docs/REQUIREMENTS.md#311-开放插件平台plugins--developer-ecosystem) 和 [ADR-0003](../docs/adr/0003-plugins-js-first.md)。

| 目录 | 内容 | 状态 |
|---|---|---|
| [`schema/plugin.schema.json`](schema/plugin.schema.json) | `plugin.json` 清单的**唯一定义**（Rust 端 `PluginManifest` 必须和它一致）| 1.2 |
| [`js/`](js/) | `@lekis/plugin-sdk`：TypeScript 类型定义 | 1.2 |
| [`wit/lekis-plugin.wit`](wit/lekis-plugin.wit) | WASM 插件接口 | 1.x 草案 |
| [`examples/lrclib-lyrics/`](examples/lrclib-lyrics/) | 最小示例：LRCLIB 歌词 | 可读 |
| [`examples/video-playback/`](examples/video-playback/) | 可选视频页兼容层：B 站 / YouTube | 可读 |

宿主现状：JS 运行时（`lekis-plugin-host`，rquickjs）和 App 内本地插件管理（文件夹 / zip 安装、启用、权限、设置、删除）已经可用；WASM 运行时、GitHub topic 索引、脚手架 CLI 还没做（1.0 / 1.x）。

## 一个插件长什么样

```
my-plugin/
├── plugin.json      清单（必须）
├── index.js         入口：每个能力导出一个函数
└── locales/         多语言（可选）
    ├── zh-CN.json
    └── en.json
```

- **入口必须是 JavaScript**：宿主不转译 TypeScript，也不解析模块间 import。TypeScript 插件须预先编译 / 打包成单个 JS 文件。
- **每个能力导出一个函数**，参数是一个对象，返回一个对象（或 `null`）。没导出的能力就是不支持。
- **默认零权限**：网络只能访问 `permissions.network` 里列出的域名，而且只能用 HTTPS。
- 出错时抛 `PluginError`（`signIn` / `setup` / `unavailable` / `unsupported` / `rateLimited`），App 会据此提示用户。

## 发布

把插件打包成含 `plugin.json` 和 JS 入口的目录或 zip，可从 App 的「设置 → 插件」安装。GitHub topic 自动索引尚未实现。

## 版本规则

- `apiVersion` 是插件 API 版本。宿主只加载**主版本号相同**的插件；次版本号增加只会新增可选能力和字段。
- 破坏性变更需要新的 ADR，并且至少提前一个大版本标记废弃。

## 音源搜索与播放（API 1.1）

JS 音源插件声明 `kinds: ["source"]`，导出 `search({query,type,cursor?,limit?})` 和 `stream({id,quality})`。App 搜索页会列出已启用的音源插件，目前只查询 `type: "track"` 的第一页。Rust 门面提供 `search_plugin(plugin_id, query, limit)`，桥接层同名；返回普通 `SearchResults`，能直接使用现有队列、收藏、歌单与播放详情。

搜索结果以 `SourceKind::Plugin` 和插件原始歌曲 ID 追加到资料库。新搜索不会删除旧搜索的歌曲引用。播放解析器在每次播放时调用 `stream`，校验 `permissions.network`、请求头域名权限和 `expiresAt`，再交给原生 HTTP Range / 解码链路；临时地址不写入数据库。搜索和浏览曲目可附带 `artworkUrl`；MyGO 的 `imageUrl`（含专辑封面回退）会适配为该字段。宿主按插件网络权限保存地址，界面通过既有 `artwork(trackId)` 按需下载、解码并生成 128/256/512/1024 WebP 缓存，关联普通 `artwork_id`；界面只读取本地 `artworkPath`。每个重定向都检查原插件权限，不转发音频凭据；下载最多 8 MiB，图片最大 8192×8192、解码分配最多 64 MiB。封面下载最多四个并发，同曲目请求去重，失败只显示占位图并退避 30 秒，不阻断搜索或播放。重新搜索会为旧导入曲目补封面元资料，播放也可后台按原始 ID 精确回填；不会覆盖用户已指定的封面。MyGO 兼容音源可从搜索页或插件详情进入公开内容浏览，支持目录导航。通用浏览接口支持游标分页，MyGO 的公开 browse 协议本身不声明游标。原生 Lekis browse 可通过桥接接口调用。

### 官方视频页（API 1.2）

音源插件可以在 `kinds` 里额外声明 `"video"`，并导出 `video({id})`，返回当前曲目对应的官方页面：

```ts
export async function video({ id }: VideoParams): Promise<VideoResult> {
  return { url: `https://player.example.com/embed/${id}`, title: "MV" };
}
```

`url` 必须是 HTTPS，主机名必须出现在 `permissions.network` 里。宿主只打开这个页面（macOS / Android / Windows / Linux 都优先内嵌受限 WebView，运行时不完整时退回系统浏览器），不会解析、下载或转存视频流。App 附带官方“视频播放”插件并默认开启，插件本身有启用开关；用户也可以在设置里关闭整个视频入口。详细边界见 [ADR-0011](../docs/adr/0011-video-playback.md)。

独立视频插件（`kinds: ["video"]`、不包含 `source`）作为兼容层时，同一个 `video` 能力收到的参数是 `{sourcePluginId, externalId, title?, artists?}`，返回同样的 `{url, title?}`。App 先问音源插件，再问已启用的独立视频插件，最后才用内置 B 站兜底。参考实现见 [`examples/video-playback/`](examples/video-playback/)。

插件执行时读取 App 已保存的设置，包括密码项（密码仍不在详情接口回显）。同一插件的运行时缓存会随代码、设置、进程授权变动而重建；`host.storage` 按插件配额持久化到 `plugin-data/<id>/storage.json`，跨 App 重启和运行时重建保留；每次调用（包括执行后报错）都会保存。Unix 目录/文件权限为 0700/0600。该 JSON 不是系统钥匙串，请勿把它理解为加密凭据库。插件调用串行；调用者取消后，实际执行和持久化仍会完成，卸载等待该任务结束。网页登录等尚未落地的宿主 API 仍会明确返回不支持。

### 外部程序

`host.spawn(program, args)` 现在有桌面实现。程序必须同时出现在清单 `permissions.process` 中和用户授予的程序列表中。用户在插件详情里逐项授予或撤销，默认关闭；卸载会清除授权。授权记录在宿主设置 `plugin.process.<plugin id>.<program>`，插件的 `host.setting` 无权修改它。

调用不经过 shell，不接收 stdin；超时 45 秒并终止子进程，stdout / stderr 各限制 8 MiB。音源插件调用的 JS 时间上限为 60 秒；独立调用的 `JsRuntime` 仍默认 15 秒。外部程序以当前用户权限运行，网络和文件访问不受 JS 沙箱限制，不能把程序授权视为网络域名授权。

### 通用在线验收

```sh
cd core
cargo run -p lekis-core --example source_plugin_smoke -- \
  /path/to/plugin 'search text or song link' --allow-process PROGRAM
```

工具使用临时资料库，经过真实 QuickJS 宿主、插件搜索、媒体解析和原生解码器，读取约两秒音频，不向扬声器输出。无需外部程序的插件可以省略最后两个参数。

## Android 原生扩展（API 1.2）

插件可随包携带 Android `.dex` 或包含 `classes.dex`、`classes2.dex` 等的 `.jar` 容器，由 App 注册的通用执行器调用。JAR 必须存放 Android DEX，不能直接使用 JVM 字节码 JAR；多 DEX 可用于打包 desugar 依赖。声明示例：

```json
{
  "native": {
    "android": {
      "entry": "android/classes.dex",
      "className": "dev.example.music.NativePlugin"
    }
  }
}
```

`entry` 必须是插件目录内的普通文件；安装及调用检查相对路径、目录边界和符号链接。入口与类名由清单和管理器选择，JS 只能传操作名与 JSON 参数：

```js
if (!host.native.available) {
  throw new PluginError("setup", "请在插件权限中允许 Android 原生扩展");
}
const result = await host.native.call("search", { query: "music" });
```

原生代码拥有 App 的全部权限，超出 QuickJS 网络/存储沙箱；只应授权可信插件。启用插件、授予桌面外部程序权限或注册执行器都不会授予原生权限。独立授权保存为 `plugin.native.<pluginId>.android`，只有字符串 `true` 表示允许，默认拒绝；撤销会等待已有 JS/桥接调用结束并清除运行时缓存，卸载删除授权。桥接超时后，底层原生线程仍可能运行并占用执行配额；撤权只阻止后续调用，不会强制终止该线程。更改授权会重建运行时。`available` 仅在 Android、声明与入口有效、授权存在且执行器已注册时为真，桌面/iOS 恒为假。未授权的直接调用会返回 `setup` 错误，平台或执行器不可用返回 `unsupported`。

宿主只提供 `AndroidNativeSpec`、`NativePluginRequest`、`NativePluginExecutor` 与 `register_native_plugin_executor` 合同，不包含服务代码或 DEX/JNI 实现。重复注册同一个执行器 Arc 幂等，进程中不允许替换为另一个实例。Android 集成实现加载器及 Java JSON 调用协议；插件原生代码的生命周期和线程行为由该执行器管理，JS 超时不会强制终止已经进入的原生函数。

## MyGO 插件兼容

可以从文件夹或 zip 安装使用下述接口子集的 MyGO 单文件 JavaScript 插件。宿主在没有 `apiVersion` 而存在 `main` 时识别原版清单，将 ID 映射为 `dev.mygo.<id>`，默认 `playback` 为 `stream`；原版 `minAppVersion` 属于 MyGO，不作为 Lekis 的最低版本。MyGO 本体是 AGPL；此兼容层根据公开接口独立实现，不复制其实现。兼容目标是常见只读音源能力。

| 能力 | 本次范围 |
|---|---|
| search | 将 Lekis `type` 转为 MyGO `kind` 的 `tracks/albums/artists/playlists`，游标转为非负 `offset`；适配艺人对象、毫秒时长、曲目字段及 `more`；App 搜索为第一页 |
| stream | `normal/low` 转 `standard`，保留 `high/lossless`；适配 `type` 为 MIME；验证媒体域名和 `stream` 返回的请求头 |
| home / browse / album / playlist / artist | 公开目录与曲目列表；只有原插件对应导出存在时才可调用；MyGO browse 不提供游标分页 |
| lyrics | `{id}` → `{lrc,translation?}`；需要来源歌曲 ID，不支持逐字 `lines` |
| fetch 返回对象 | 域名校验、重定向逐跳校验；支持 `status/ok/url/headers.get()`、`text()/json()`、文本请求体与超时/取消；响应体上限 8 MiB |
| URL / timers | URL 解析及查询参数；`setTimeout/clearTimeout`、AbortController；每个上下文最多 256 个待执行定时器，受插件调用期限约束 |
| storage / setting / t | 同步 JSON storage；setting 返回字符串；`t/language` 使用语言文件；storage 跨启动持久化 |
| MD5 / platform | 兼容签名摘要、平台及架构判断；MD5 不用于安全加密 |
| 登录 / 远程播放 / 后台进程 | 暂不支持，返回明确错误；远程播放清单拒绝安装 |
| TypeScript / 模块导入 | 需要插件预先打包为单个 JavaScript 文件 |

浏览桥接：`browse_plugin(plugin_id, path, cursor)` 返回 folders、普通曲目行和 next 游标。原生 Lekis `browse({path,cursor})` 返回 `{items:[{kind:'folder',id,title}, {kind:'track',id,title,artists,durationMs}],next?}`；文件夹 ID 是不透明路径。

歌单页的「在线歌单与榜单」汇集已启用的音源。插件可用 `kind:'playlist'` 或 `kind:'chart'` 返回歌单或榜单目录。订阅保存插件 ID 和目录 ID，重新打开或刷新时调用插件读取当前内容。目录 ID 应跨版本保持稳定，不要使用会过期的播放地址。

MyGO 根目录调用 `home()`，`page:<id>` 调用 `browse({page:id})`；两者读取 `{sections:[{tracks,albums,artists,playlists,links,morePage}]}`，其中 `links` 使用 `{title,page,subtitle?,imageUrl?}`。`album:<id>` 读取 `album({id})` 的 `{album,tracks}`，`artist:<id>` 读取 `artist({id})` 的 `{artist,tracks,albums}`，`playlist:<id>` 读取 `playlist({id})` 的歌单及 `tracks`。分区中的曲目展开为普通曲目，实体、链接及 `morePage` 转为目录；页面标题与分区布局不保留。原插件没有 `home` 时，打开根目录会明确报不支持，不从清单 `navigation` 自动生成首页。

权限默认值与标头范围：未声明 `permissions.network` 时不能访问网络；允许显式域名及 `*.example.com`，不接受 `["*"]` 或动态域名。默认私有存储配额为 1024 KiB，按键和值的 UTF-8 字节数计费，`storageKb` 可覆盖。进程声明只接受精确程序名/路径，仍不提供 MyGO 后台进程句柄。MyGO 的网络域名会同时成为 `stream` 返回标头的允许域名，播放前仍校验实际媒体地址。原版 `requestHeaders` 规则只接受省略 `kinds`、hosts 与 network 声明完全一致、无设置/存储占位符的字符串规则；目前只用其域名授权，固定头值尚未自动注入播放请求，图片请求也未接入。依赖这些固定规则鉴权的插件尚不兼容，应由 `stream` 主动返回所需 `headers`。

此外，AES、文件系统路径、二进制 fetch、interval timers、逐字歌词、动态请求头规则、按媒体类型区分的 `requestHeaders.kinds`、导航 actions 尚未适配。URL 的部分属性写入会明确报不支持。fetch 取消会及时拒绝 JS Promise，底层请求仍受超时和每插件 8 个并发请求上限约束。第三方插件的其他导出不一定有对应 App 界面。兼容不能保证绕过上游服务的地区限制、登录要求或风控。独立 Bilibili 包保留原始 MIT 代码与清单；公开搜索、首页/榜单和普通 AAC 音频为验证范围，需要网页登录或长驻 ffmpeg 的路径不在本次范围内。

## 红线

官方仓库不接受任何第三方流媒体音源插件（YouTube、网易云、QQ 音乐等）。见 [CONTRIBUTING.md](../CONTRIBUTING.md) 第 7 节。

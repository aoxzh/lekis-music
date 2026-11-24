# 视频播放（官方插件）

App 随包附带并默认启用的官方插件：给没有导出 `video` 能力的音源提供官方视频页映射。

- 当前支持 `dev.mygo.bilibili`（B 站投稿 / 多 P 视频）和常见 YouTube 音源 ID。
- 只返回官方页面地址，不解析视频流。
- 音源插件自己导出 `video` 时，App 会优先使用音源的结果；这个插件只在音源没有提供时兜底。
- 插件本身有启用开关；关闭后 B 站的内置兜底也不再显示。用户还可以在「设置 → 播放 → 视频播放」关闭整个入口。
- `app/assets/plugins/video-playback/` 是 App 内置的同一份副本；修改插件时两边要同步。

插件权限只需要 `api.bilibili.com`（多 P 元数据）、`player.bilibili.com` 和 YouTube 页面域名。

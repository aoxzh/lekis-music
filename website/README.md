# 月兔音乐官网作者预览包

解压整个 `lekis-author-site.zip`，双击 `lekis-author-site/index.html` 即可预览。页面、配图和插件 ZIP 都可离线打开。页面按浏览器语言显示简体中文或英文，也可以在页首切换。应用安装包请从首页底部的作者 GitHub Releases 链接获取。

## 体验 Bilibili

1. **带默认社区插件库的构建**。从「设置 → 高级 → 插件」或「添加音源 → 导入在线音源」进入插件页，点「浏览插件目录」。找到 Bilibili 后选择「下载并安装」，核对版本和地址，再确认。应用会比对插件 ZIP 与目录中的 SHA-256。
2. **目录暂不可用，或使用支持 MyGo 音源插件的旧版**。在官网「在线音源 · Bilibili」下载 ZIP，或直接取本包的 `plugins/bilibili.zip`。在应用的「插件」页选择「从 .zip 安装」，选中完整 ZIP。没有 MyGo 音源支持的旧版需先升级到兼容构建。
3. **试听**。确认 Bilibili 已启用，在「搜索」中将范围切为 Bilibili，输入关键词、BV 号或视频链接。安装 ZIP 可以离线操作，搜索和播放 B 站内容需要联网。

## 目录与插件来源

计划公开的社区目录位于 <https://github.com/hal-pixel/lekis-plugin-registry>。兼容构建默认读取该仓库 `main` 分支的 `catalog.json`。插件和目录均由第三方独立维护，与月兔音乐及哔哩哔哩官方均无隶属或背书关系。内容与服务由相应提供方负责。本官网包仅在本地整理，供私发作者审阅。

本包的 `plugins/bilibili.zip` 直接取自目录的 `packages/bilibili.zip`，与 `catalog.json` 的 `dev.mygo.bilibili` 条目对应。版本为 `0.5.0-lekis.1`，SHA-256 为 `ac94435f96d1b81975e45112c80aab18eeb7626ec6095e3b74e07484dd4ac39e`。在站点目录运行 `shasum -a 256 plugins/bilibili.zip` 可复核。将来更新时，同步目录生成的完整 ZIP，核对版本及校验值，再重打官网包。

插件基于 GentleM4dman 的 MyGo Bilibili 插件，采用 MIT 许可，来源与许可见插件 ZIP 内的 `SOURCE.md` 和 `LICENSE`。官网保留原项目的域名配置、搜索引擎文件和 MPL-2.0 许可。播放器和手机配图来自原项目的 `docs/screenshots`，品牌图标来自 `app/assets/brand`。

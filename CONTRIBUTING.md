# 贡献指南

## 1. 开始之前

1. 读 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，搞清楚你要改的代码属于哪一层、允许依赖谁。
2. 在 [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) 里找到对应的需求编号（例如 `LIB-05`、`PLY-01`），PR 标题和描述里要写上。
3. 如果你的改动违反了架构文档里的任何一条规则，或者要引入新的重要依赖，**先写 ADR，评审通过后再写代码**。

## 2. 分支

| 分支 | 用途 |
|---|---|
| `main` | 随时可编译、CI 全绿。只能通过 PR 合入 |
| `feat/<需求编号>-<简述>` | 新功能，例如 `feat/LIB-05-shared-index` |
| `fix/<简述>` | 修 bug |
| `chore/<简述>` / `docs/<简述>` | 杂项 / 文档 |
| `release/<代号>` | 发布分支：`release/luna`（Alpha）、`release/lekis`（Beta）、`release/cresce`（1.0）、`release/diana`（2.0）|

## 3. 提交信息

使用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/)，scope 用模块名：

```
feat(scanner): 支持 NAS 共享索引的增量校验 (LIB-05)
fix(playback): 修复 AAC 无缝播放时编码器延迟没有去掉的问题 (PLY-01)
refactor(ffi): 把 TrackDto 拆成列表用和详情用两种
```

核心用 crate 名：`types` `vfs` `library` `scanner` `providers` `enrich` `playback` `sync` `plugin` `core` `bridge` `node`；Flutter 端用功能模块名：`app` `shell` `library` `now-playing` `lyrics` `player` `playlists` `sources` `settings` `plugins` `offline` `ui` 等；其他：`android` `windows`（平台工程）`plugin-sdk` `design` `tools` `build` `ci` `docs`。

## 4. Pull Request

- 一个 PR 只做一件事。超过 800 行（不含生成代码和测试数据）要拆分。
- 必须通过 CI：`cargo fmt`、`cargo clippy -D warnings`、`cargo test`、`cargo deny`（`core.yml`），以及 `flutter analyze`、`flutter test`、Android arm64 release 构建（`app.yml`）。
- 改了 `lekis-bridge/src/api/`：同一个 PR 里必须重新生成 Dart 绑定（`cd app && flutter_rust_bridge_codegen generate`）并提交 `app/lib/src/rust/` 和 `lekis-bridge/src/frb_generated.rs`。冻结的 `lekis-ffi` 不再加接口。
- 改了数据库表结构：**只能新增迁移文件**，不能修改已经合入的迁移文件。
- 改了插件接口（`plugin-sdk/`）：按语义化版本处理，破坏性变更需要 ADR。
- 改了设计 Token：同步更新 `app/lib/src/theme/tokens.dart`。
- UI 改动要附截图（深色 + 浅色；涉及布局的话手机 + 桌面）。

## 5. ADR（架构决策记录）

以下情况需要写 ADR：引入新的第三方依赖（核心层）、新增或拆分 crate、改变线程模型、改变 FFI 方式、改变数据存储方式、改变插件协议。

复制 [docs/adr/0000-template.md](docs/adr/0000-template.md)，编号递增，状态从"提议"开始，评审通过后改为"已采纳"。

## 6. 复用与许可证

项目许可证是 **MPL-2.0**，原则是**复用优先**：写新模块前先查 [docs/REUSE.md](docs/REUSE.md)，能用现成的库或代码就不要自己写。完整规则见 [ADR-0007](docs/adr/0007-license-and-reuse-first.md)，简单说：

- ✅ MIT、Apache-2.0、BSD、ISC、Zlib、MPL-2.0、CC0：可以作为依赖，也可以**直接拷代码**（保留原版权头，登记到 `THIRD_PARTY_NOTICES.md`，提交说明写清来源）。
- 🟡 LGPL：只能动态链接或作为可替换组件，单独评审。
- 🔒 GPL / AGPL（Navidrome、Jellyfin、Feishin、mygo-music、AMLL 等）：可以读、可以学思路、可以实现同样的公开协议和格式；**不拷代码，也不逐行翻译**。
- ❌ 非商用条款或专有许可（MusicFree、Musly、Harmonoid、Namida）：不碰。
- `cargo deny check licenses` 必须通过。

## 7. 法律红线

- **不要**往仓库里提交任何第三方流媒体（YouTube、网易云、QQ 音乐等）的音源插件或破解代码。

## 8. 隐私自检

这个仓库要公开，提交前会跑一遍 [`tools/check-privacy.sh`](tools/check-privacy.sh)（Windows 上是
[`tools/check-privacy.ps1`](tools/check-privacy.ps1)），拦截：

- 本机的绝对路径（Windows 盘符路径、`/Users/`、`/home/` 下的家目录）
- 邮箱、GitHub Token、私钥、疑似 API Key
- `.env`、`local.properties`、证书和密钥文件

手动检查：

```bash
./tools/check-privacy.sh            # 检查暂存区
./tools/check-privacy.sh --tree     # 检查整个仓库
```

配置和日志里如果要举例路径，用 `~/Music`、`/volume1/music` 这类通用写法。

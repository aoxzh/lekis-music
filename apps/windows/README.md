# Lekis Music — Windows

> **已冻结**（[ADR-0006](../../docs/adr/0006-flutter-ui.md)）：UI 已改用 Flutter（[`app/`](../../app/)）。这里不再加功能、不作为日常构建目标，Alpha 退出后连同 `core/crates/lekis-ffi`、`tools/gen-bindings.*`、`tools/build-*-core.*` 和对应 CI 一起删除。下面的内容只作历史参考。

C# / .NET 10 + WinUI 3（Windows App SDK 2.7）+ CommunityToolkit.Mvvm + Microsoft.Extensions.DependencyInjection。
免打包（unpackaged）+ 自包含 Windows App SDK，`dotnet build` 完直接跑 `bin` 下的 `Lekis.exe`。

## 环境要求

| 需要 | 说明 |
|---|---|
| .NET SDK 10 | <https://dotnet.microsoft.com/download>。本仓库在 10.0.404 上验证过 |
| Windows 10 2004（19041）或更高 | `TargetPlatformMinVersion` / `SupportedOSPlatformVersion` 见 `Directory.Build.props` |
| NuGet 能访问 nuget.org | 包版本统一在 `Directory.Packages.props`，不要在 csproj 里写版本 |

**不需要 Visual Studio**。也不需要 MSVC：Windows 应用只是调用核心，不编 Rust 代码（编核心见下一节）。
如果装了 VS 2022，装 "Windows 应用开发" 工作负载会更方便（XAML 设计器、调试），但不是构建的前提。

## 构建

```powershell
# 在仓库根目录：默认配置（Debug）+ x64
dotnet build apps/windows -p:Platform=x64

# 指定配置；ARM64 机器 / 交叉编译用 ARM64
dotnet build apps/windows -p:Platform=x64 -c Release
dotnet build apps/windows -p:Platform=ARM64
```

也可以直接编项目：

```powershell
dotnet build apps/windows/src/Lekis.App/Lekis.App.csproj -p:Platform=x64
```

输出：

```
apps/windows/src/Lekis.App/bin/<Platform>/<Configuration>/net10.0-windows10.0.26100.0/win-<arch>/Lekis.exe
```

> **平台必须是 x64 或 ARM64。** 这个项目不支持 AnyCPU：Windows App SDK 的自包含模式下
> `Microsoft.WindowsAppSDK.SelfContained.targets` 需要明确的 Windows 架构，传 AnyCPU 会报
> `WindowsAppSDKSelfContained requires a supported Windows architecture`。
> 解决方案文件 `Lekis.Windows.sln` 里只登记了 `Debug|ARM64` / `Debug|x64` / `Release|ARM64` / `Release|x64`
> 四个配置，所以 `-p:Platform=` 会被正确带到两个项目里；**不要**手加 `Any CPU` 配置。

## 运行

```powershell
# 免打包（WindowsPackageType=None）→ 直接起 exe，不需要装 MSIX
apps/windows/src/Lekis.App/bin/x64/Debug/net10.0-windows10.0.26100.0/win-x64/Lekis.exe
```

当前**没有 Rust 绑定**（`src/Lekis.Core.Interop/Generated/lekis_ffi.cs` 不存在），
`CoreServiceFactory` 会返回 `FakeCoreService`，所以界面上的歌是示例数据，设置页顶部会显示
"假核心"的 `InfoBar` 提示。这是预期行为，不是 bug。

有绑定文件时 `RustCoreService.cs` 才会被编译（`Lekis.Core.Interop.csproj` 里按
`Generated/lekis_ffi.cs` 是否存在定义 `LEKIS_BINDINGS`），也就是说先把绑定生成出来再编。

要换成真实核心：

```powershell
# 1. 编 Rust 核心（发布用 MSVC，本机只有 GNU 工具链时加 -Target x86_64-pc-windows-gnu）
./tools/build-windows-core.ps1

# 2. 生成 C# 绑定（需要 uniffi-bindgen-cs）
cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.9.0+v0.28.3
./tools/gen-bindings.ps1

# 3. 重新构建：Generated/lekis_ffi.cs 存在时项目自动定义 LEKIS_BINDINGS
dotnet build apps/windows -p:Platform=x64
```

`RustCoreService.cs` 里的名字是按 uniffi-bindgen-cs 的命名规则推测的，第一次生成绑定后大概率要修，
修的是**桥接层**，不是 UI。

## 目录结构

```
apps/windows/
├── Directory.Build.props       # 目标框架、可空警告当错误、按 Platform 推 RuntimeIdentifier
├── Directory.Packages.props    # 中央包版本管理
├── Lekis.Windows.sln           # 只含 x64 / ARM64 四个配置
└── src/
    ├── Lekis.Core.Interop/     # 核心桥接层：唯一的核心入口
    │   ├── ICoreService.cs     # 对 UI 暴露的全部能力（已定稿）
    │   ├── Models.cs           # 领域模型和枚举的 C# 镜像
    │   ├── CoreServiceFactory.cs   # 有绑定 → 真实核心；没有 → FakeCoreService
    │   ├── FakeCoreService.cs      # 示例数据（晴天 / 以父之名 / Moon River）
    │   ├── RustCoreService.cs      # 只在 Generated/lekis_ffi.cs 存在时编译
    │   ├── WindowsCredentialStore.cs
    │   └── Generated/          # 绑定输出，不提交
    └── Lekis.App/
        ├── App.xaml(.cs)       # DI 组装 + 主窗口
        ├── MainWindow.xaml(.cs)# 标题栏 + NavigationView + 底部 PlayerBar
        ├── Themes/Tokens.xaml  # 和 design/tokens.json 一致的设计 Token
        ├── Common/             # Format（含可见性 / 时长辅助）、Strings（错误码本地化）、TrackPager（增量加载）
        ├── Controls/           # TrackListItem、PlayerBar
        ├── Services/           # AppPaths、IUiDispatcher、MediaControlsService（SMTC 占位）
        ├── ViewModels/         # 7 个，全部注册为单例
        ├── Views/              # 7 个页面，和 ViewModel 一一对应
        └── Strings/<lang>/Resources.resw   # en-US / zh-CN
```

页面划分和 Android 一一对应（`docs/ARCHITECTURE.md` 第 7 节），**新增页面要两边一起加**：
`HomePage`、`LibraryPage`、`SearchPage`、`NowPlayingPage`、`SourcesPage`、`EnrichReviewPage`、`SettingsPage`
（设置页走 `NavigationView` 的内置 `IsSettingsSelected`，不在 `MenuItems` 里）。

## 代码规则（务必先读 docs/ARCHITECTURE.md）

- **UI 里不许有业务逻辑。** 业务逻辑（扫描、搜索、播放、补全、同步）全在 Rust 核心，UI 只调 `ICoreService`。
  排序、过滤、分页这些也算业务逻辑，应该交给核心或 ViewModel，不要写进 code-behind。
- **错误只按 code 本地化，不直接显示 message。** 核心抛 `CoreServiceException`，界面用
  `Common/Format.cs` 里的 `Strings.ErrorMessage(e)` 拿到 `Error_<CoreErrorKind>`，不要去显示 `e.Message`。
- **UI 线程。** 核心事件来自后台线程，进 ViewModel 时用 `IUiDispatcher.Post` 切回 UI 线程
  （事件是同步回调，不要在里面 `await`）。
- **null 警告就是错误**（`WarningsAsErrors` 含 `nullable`）。可空问题在编译期解决，不要用 `!` 压掉。
- **文字全部用 `x:Uid` + `.resw`**，不要往 XAML 里写死中文/英文。新增 key 时 en-US 和 zh-CN 都要加，
  两边 key 集合必须一致。`Sort_*` / `SourceKind_*` / `Error_*` 这些是由枚举名拼出来的
  （`EnumTextConverter` + `Strings.Get($"{Prefix}_{value}")`），改名要跟枚举一起改。
- **设计 token 只从 `Themes/Tokens.xaml` 取**，不要在页面里写死颜色 / 字重；间距沿用
  `LekisSpacing*` / `LekisPageMargin`，偶尔的字面量 `Padding` 和现有代码保持一致（如 `Padding="0,6"`）。
- 注释用中文，和现有代码保持一致。

## 已知的坑

- **解决方案文件用经典 `.sln`，不是 `.slnx`。** .NET 10 的 `dotnet new sln` 默认生成 `.slnx`，
  但 slnx 在 `dotnet build ... -p:Platform=x64` 时不会把 `Platform` 传给子项目，子项目会拿到
  `AnyCPU`，然后死在 Windows App SDK 的自包含检查上。要重建解决方案：

  ```powershell
  cd apps/windows
  dotnet new sln -n Lekis.Windows -f sln      # 注意 -f sln
  dotnet sln Lekis.Windows.sln add src/Lekis.Core.Interop/Lekis.Core.Interop.csproj src/Lekis.App/Lekis.App.csproj
  ```

  加完检查 `GlobalSection(SolutionConfigurationPlatforms)` 里只有 x64 / ARM64，两个项目的
  `ProjectConfigurationPlatforms` 都映射到真正的架构。

- **`x:Bind` 的函数绑定不支持嵌套调用。** `{x:Bind Format.VisibleIfTrue(IsEmpty(X))}` 会让 XamlCompiler
  在 MarkupCompilePass2 崩溃，而且报的是误导性的
  `WMC9999 ... Could not find any resources appropriate for the specified culture`
  （编译器加载不到自己的报错资源）。真因要看
  `src/Lekis.App/obj/<Platform>/<Configuration>/<tfm>/<rid>/output.json` 里 `MSBuildLogEntries` 的调用栈。
  写法上拆成单层辅助函数（见 `Common/Format.cs` 的 `VisibleIfZero` / `VisibleIfPositive`），或者用 `x:Bind`
  绑一个 code-behind 的 `bool` 属性/方法。

- **免打包（unpackaged）下系统选择器必须 `InitializeWithWindow`。** `FolderPicker` / `FileOpenPicker`
  在桌面应用里直接 `PickSingleFolderAsync()` 会抛异常，要先
  `WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window))`，
  见 `Views/SourcesPage.xaml.cs`。

- **`.resw` 不用在 csproj 里登记。** `Microsoft.WindowsAppSDK` 通过
  `EnableDefaultWindowsAppSdkPRIResourceItems` 自动收录 `Strings/**/*.resw`，
  放进 `src/Lekis.App/Strings/<lang>/Resources.resw` 就会编进 `Lekis.pri`。

## 之后要补的

近期优先级：SMTC 系统媒体控制（`Services/MediaControlsService.cs` 里有实现思路）、
MSIX 打包项目（要包标识才能用完整的 SMTC、开机任务、文件关联）、专辑 / 艺人视图、正在播放页的动态背景和歌词。
完整的需求清单见 [docs/REQUIREMENTS.md](../../docs/REQUIREMENTS.md)。

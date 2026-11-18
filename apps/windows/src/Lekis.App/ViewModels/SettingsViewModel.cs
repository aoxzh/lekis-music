using System.Reflection;
using CommunityToolkit.Mvvm.ComponentModel;
using Lekis.App.Services;
using Lekis.Core;

namespace Lekis.App.ViewModels;

/// <summary>
/// 设置。原型只显示版本信息。
/// TODO：主题（跟随系统 / 浅色 / 深色 / OLED 纯黑）、语言、音频输出（WASAPI 独占 / 比特完美）、ReplayGain、
/// 缓存大小、补全来源开关、插件管理、同步、隐私（崩溃报告默认关闭）。设置项的值存在核心（kv 表），不要存在 UI 侧。
/// </summary>
public sealed partial class SettingsViewModel(ICoreService core) : ObservableObject
{
    public string AppVersion { get; } =
        typeof(SettingsViewModel).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
        ?? "?";

    public string CoreVersion => core.CoreVersion;

    /// <summary>为 true 时设置页顶部显示"正在使用示例数据"提示。</summary>
    public bool IsFakeCore => core.IsFake;

    public string DataDir => AppPaths.DataDir;
}

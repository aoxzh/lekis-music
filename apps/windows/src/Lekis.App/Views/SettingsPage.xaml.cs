using Lekis.App.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace Lekis.App.Views;

/// <summary>
/// 设置。原型只显示版本 / 核心版本 / 数据目录；核心是假实现时顶部有 InfoBar 提示。
/// TODO：主题、语言、音频输出、ReplayGain、缓存、补全来源、插件、同步、隐私。
/// </summary>
public sealed partial class SettingsPage : Page
{
    public SettingsPage()
    {
        ViewModel = App.Services.GetRequiredService<SettingsViewModel>();
        InitializeComponent();
    }

    public SettingsViewModel ViewModel { get; }
}

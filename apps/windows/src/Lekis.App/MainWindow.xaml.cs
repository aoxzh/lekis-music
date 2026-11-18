using Lekis.App.Views;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;

namespace Lekis.App;

/// <summary>
/// 主窗口：标题栏 + 左侧导航 + 内容区 + 底部播放条。
/// 页面划分和 Android 一一对应（docs/ARCHITECTURE.md 第 7 节），新增页面要两边一起加。
/// </summary>
public sealed partial class MainWindow : Window
{
    private static readonly Dictionary<string, Type> Pages = new()
    {
        ["home"] = typeof(HomePage),
        ["library"] = typeof(LibraryPage),
        ["search"] = typeof(SearchPage),
        ["nowplaying"] = typeof(NowPlayingPage),
        ["sources"] = typeof(SourcesPage),
        ["enrich"] = typeof(EnrichReviewPage),
    };

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        // TODO(品牌)：Assets/AppIcon.ico 准备好之后 AppWindow.SetIcon("Assets/AppIcon.ico")。
        Nav.SelectedItem = Nav.MenuItems[0];
        Navigate(typeof(HomePage));
    }

    /// <summary>供其他页面跳转（例如首页点"查看全部"跳资料库）。</summary>
    public void NavigateTo(string tag)
    {
        var item = Nav.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(i => (string?)i.Tag == tag);
        if (item is not null) Nav.SelectedItem = item;
    }

    private void OnNavSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.IsSettingsSelected)
        {
            Navigate(typeof(SettingsPage));
        }
        else if (args.SelectedItemContainer?.Tag is string tag && Pages.TryGetValue(tag, out var page))
        {
            Navigate(page);
        }
    }

    private void Navigate(Type page)
    {
        if (ContentFrame.CurrentSourcePageType != page)
        {
            ContentFrame.Navigate(page, null, new EntranceNavigationTransitionInfo());
        }
    }
}

using System.Diagnostics;
using Lekis.App.Services;
using Lekis.App.ViewModels;
using Lekis.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Lekis.App;

/// <summary>
/// 应用入口：组装依赖（DI）并打开主窗口。
/// 规则：页面通过 <see cref="Services"/> 拿 ViewModel；ViewModel 通过构造函数拿服务；
/// 除了这里，任何地方都不要 new 服务。
/// </summary>
public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            // TODO(OBS-*)：接入本地崩溃日志（不上传，除非用户在设置里同意）。
            Debug.WriteLine($"[lekis] unhandled: {e.Exception}");
        };
    }

    /// <summary>全局服务容器。只在页面 / 控件的 code-behind 里用来取 ViewModel。</summary>
    public static IServiceProvider Services { get; private set; } = null!;

    /// <summary>主窗口（文件选择器等需要窗口句柄的系统 API 用）。</summary>
    public static MainWindow? MainWindow { get; private set; }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Services = ConfigureServices();
        _window = new MainWindow();
        MainWindow = _window;
        Services.GetRequiredService<MediaControlsService>().Attach(_window);
        _window.Closed += (_, _) => (Services as IDisposable)?.Dispose();
        _window.Activate();
    }

    private static ServiceProvider ConfigureServices()
    {
        var services = new ServiceCollection();

        services.AddSingleton<IUiDispatcher>(new DispatcherQueueUiDispatcher(DispatcherQueue.GetForCurrentThread()));
        services.AddSingleton<ICoreService>(_ => CoreServiceFactory.Create(AppPaths.CoreOptions()));
        services.AddSingleton<MediaControlsService>();

        // ViewModel 都是单例：和 Android 上"ViewModel 跟随导航目的地"的效果一样，切页面回来状态还在。
        // 以后支持多窗口时再改成按窗口作用域。
        services.AddSingleton<PlayerViewModel>();
        services.AddSingleton<HomeViewModel>();
        services.AddSingleton<LibraryViewModel>();
        services.AddSingleton<SearchViewModel>();
        services.AddSingleton<SourcesViewModel>();
        services.AddSingleton<EnrichReviewViewModel>();
        services.AddSingleton<SettingsViewModel>();

        return services.BuildServiceProvider();
    }
}

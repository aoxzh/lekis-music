using Lekis.App.ViewModels;
using Lekis.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace Lekis.App.Views;

/// <summary>
/// 音源管理。选文件夹是唯一需要平台 API 的地方（FolderPicker），
/// 添加 / 扫描逻辑全部在 <see cref="SourcesViewModel"/> → 核心。
/// </summary>
public sealed partial class SourcesPage : Page
{
    public SourcesPage()
    {
        ViewModel = App.Services.GetRequiredService<SourcesViewModel>();
        InitializeComponent();
    }

    public SourcesViewModel ViewModel { get; }

    private async void OnAddLocalFolderClick(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.MusicLibrary };
        picker.FileTypeFilter.Add("*");

        // 免打包（unpackaged）应用必须把 Picker 关联到窗口，否则会抛异常。
        if (App.MainWindow is { } window)
        {
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
        }

        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;

        // 显示名先用文件夹名；核心会把它存成音源名称，之后可以在音源页改名。
        await ViewModel.AddLocalFolderAsync(folder.Path, folder.Name);
    }

    private async void OnRescanClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: Source source })
        {
            await ViewModel.RescanAsync(source);
        }
    }
}

using Lekis.App.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Lekis.App.Views;

/// <summary>
/// 首页。原型只有"最近添加"；空资料库时引导去音源页添加。
/// 业务逻辑（取哪 20 首）在 <see cref="HomeViewModel"/>，这里只做展示和跳转。
/// </summary>
public sealed partial class HomePage : Page
{
    public HomePage()
    {
        ViewModel = App.Services.GetRequiredService<HomeViewModel>();
        InitializeComponent();
    }

    public HomeViewModel ViewModel { get; }

    private void OnTrackClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is Lekis.Core.TrackRow track) ViewModel.Play(track);
    }

    private void OnAddSourceClick(object sender, RoutedEventArgs e) => App.MainWindow?.NavigateTo("sources");
}

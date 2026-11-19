using Lekis.App.ViewModels;
using Lekis.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace Lekis.App.Views;

/// <summary>搜索。防抖和丢弃过期结果都在 <see cref="SearchViewModel"/> 里。</summary>
public sealed partial class SearchPage : Page
{
    public SearchPage()
    {
        ViewModel = App.Services.GetRequiredService<SearchViewModel>();
        InitializeComponent();
    }

    public SearchViewModel ViewModel { get; }

    private void OnTrackClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is TrackRow track) ViewModel.Play(track);
    }
}

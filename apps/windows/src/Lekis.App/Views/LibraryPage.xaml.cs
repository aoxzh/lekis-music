using Lekis.App.ViewModels;
using Lekis.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace Lekis.App.Views;

/// <summary>资料库（歌曲视图）。排序交给 <see cref="LibraryViewModel"/>，分页由 TrackPager 处理。</summary>
public sealed partial class LibraryPage : Page
{
    private bool _syncingSort;

    public LibraryPage()
    {
        ViewModel = App.Services.GetRequiredService<LibraryViewModel>();
        InitializeComponent();
        SyncSortFromViewModel();
    }

    public LibraryViewModel ViewModel { get; }

    private void OnTrackClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is TrackRow track) ViewModel.Play(track);
    }

    /// <summary>排序变化只来自用户操作；ViewModel 内部 Reload 不会改动 <see cref="LibraryViewModel.Sort"/>。</summary>
    private void OnSortSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingSort) return;
        if (SortBox.SelectedItem is TrackSort sort) ViewModel.Sort = sort;
    }

    private void SyncSortFromViewModel()
    {
        _syncingSort = true;
        try
        {
            SortBox.SelectedItem = ViewModel.Sort;
        }
        finally
        {
            _syncingSort = false;
        }
    }
}

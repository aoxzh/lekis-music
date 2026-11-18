using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Lekis.App.Services;
using Lekis.Core;

namespace Lekis.App.ViewModels;

/// <summary>
/// 首页。原型只有"最近添加"。
/// TODO：继续播放、每日混音、"好久没听"、按时段推荐（这些列表都由核心计算，UI 只负责展示）。
/// </summary>
public sealed partial class HomeViewModel : ObservableObject
{
    private const int RecentCount = 20;
    private readonly ICoreService _core;
    private readonly PlayerViewModel _player;

    public HomeViewModel(ICoreService core, IUiDispatcher ui, PlayerViewModel player)
    {
        _core = core;
        _player = player;
        _core.EventReceived += (_, e) =>
        {
            if (e is CoreEvent.LibraryChanged { Scope: LibraryScope.Catalog }) ui.Post(() => _ = RefreshAsync());
        };
        _ = RefreshAsync();
    }

    public ObservableCollection<TrackRow> RecentlyAdded { get; } = [];

    [ObservableProperty]
    public partial bool IsLibraryEmpty { get; set; }

    public void Play(TrackRow track)
    {
        var ids = RecentlyAdded.Select(t => t.Id).ToList();
        var index = ids.IndexOf(track.Id);
        if (index >= 0) _player.PlayTracks(ids, index);
    }

    private async Task RefreshAsync()
    {
        try
        {
            var list = await _core.ListTracksAsync(TrackSort.RecentlyAdded, 0, RecentCount);
            RecentlyAdded.Clear();
            foreach (var t in list) RecentlyAdded.Add(t);
            IsLibraryEmpty = list.Count == 0;
        }
        catch (CoreServiceException)
        {
            IsLibraryEmpty = true;
        }
    }
}

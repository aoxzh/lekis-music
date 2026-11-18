using CommunityToolkit.Mvvm.ComponentModel;
using Lekis.App.Common;
using Lekis.App.Services;
using Lekis.Core;

namespace Lekis.App.ViewModels;

/// <summary>
/// 资料库（歌曲视图）。分页逻辑和 Android 的 LibraryViewModel 一致（每页 <see cref="PageSize"/> 条）。
/// TODO：专辑 / 艺人 / 歌单 / 文件夹 视图；字母索引条；"按当前排序播放整个资料库"需要核心提供按查询播放的接口。
/// </summary>
public sealed partial class LibraryViewModel : ObservableObject
{
    public const int PageSize = 200;

    private readonly ICoreService _core;
    private readonly PlayerViewModel _player;

    public LibraryViewModel(ICoreService core, IUiDispatcher ui, PlayerViewModel player)
    {
        _core = core;
        _player = player;
        Tracks = CreatePager(TrackSort.Title);
        _core.EventReceived += (_, e) =>
        {
            if (e is CoreEvent.LibraryChanged { Scope: LibraryScope.Catalog }) ui.Post(Reload);
        };
    }

    public IReadOnlyList<TrackSort> SortOptions { get; } = Enum.GetValues<TrackSort>();

    [ObservableProperty]
    public partial TrackSort Sort { get; set; }

    [ObservableProperty]
    public partial TrackPager Tracks { get; set; }

    partial void OnSortChanged(TrackSort value) => Reload();

    public void Reload() => Tracks = CreatePager(Sort);

    public void Play(TrackRow track)
    {
        var ids = Tracks.Select(t => t.Id).ToList();
        var index = ids.IndexOf(track.Id);
        if (index >= 0) _player.PlayTracks(ids, index);
    }

    private TrackPager CreatePager(TrackSort sort) =>
        new((offset, limit) => _core.ListTracksAsync(sort, offset, limit), PageSize);
}

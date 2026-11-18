using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Lekis.App.Services;
using Lekis.Core;

namespace Lekis.App.ViewModels;

/// <summary>
/// 底部播放条 + 正在播放页共用。除了 <see cref="MediaControlsService"/>，只有这里可以调用核心的播放控制。
///
/// TODO(4.5.3)：封面取色流动背景、歌词（逐字高亮 + 弹簧滚动，参数见 design/tokens.json motion.spring.lyricsScroll）、
/// 循环 / 随机 / 收藏按钮、音量、输出设备选择、比特完美标识。
/// </summary>
public sealed partial class PlayerViewModel : ObservableObject
{
    private readonly ICoreService _core;
    private readonly IUiDispatcher _ui;
    private long? _loadedTrackId;

    public PlayerViewModel(ICoreService core, IUiDispatcher ui)
    {
        _core = core;
        _ui = ui;
        Title = string.Empty;
        Subtitle = string.Empty;
        _core.PlaybackChanged += (_, s) => _ui.Post(() => Apply(s));
        Apply(_core.Playback);
    }

    [ObservableProperty]
    public partial bool HasTrack { get; set; }

    [ObservableProperty]
    public partial bool IsPlaying { get; set; }

    [ObservableProperty]
    public partial string Title { get; set; }

    [ObservableProperty]
    public partial string Subtitle { get; set; }

    [ObservableProperty]
    public partial string? QualityBadge { get; set; }

    /// <summary>毫秒（double，直接绑 Slider）。</summary>
    [ObservableProperty]
    public partial double PositionMs { get; set; }

    [ObservableProperty]
    public partial double DurationMs { get; set; }

    [RelayCommand]
    private void TogglePlayPause()
    {
        if (IsPlaying) _core.Pause();
        else _core.Play();
    }

    [RelayCommand]
    private void Next() => _core.Next();

    [RelayCommand]
    private void Previous() => _core.Previous();

    public void SeekTo(double positionMs) => _core.Seek((long)positionMs);

    /// <summary>从列表播放（资料库 / 搜索 / 首页调用）。</summary>
    public void PlayTracks(IReadOnlyList<long> trackIds, int start) => _core.PlayTracks(trackIds, start);

    private void Apply(PlaybackSnapshot s)
    {
        HasTrack = s.TrackId is not null;
        IsPlaying = s.State == PlaybackState.Playing;
        PositionMs = s.PositionMs;
        DurationMs = Math.Max(1, s.DurationMs);
        if (s.TrackId != _loadedTrackId)
        {
            _loadedTrackId = s.TrackId;
            _ = LoadTrackAsync(s.TrackId);
        }
    }

    private async Task LoadTrackAsync(long? trackId)
    {
        if (trackId is not { } id)
        {
            Title = string.Empty;
            Subtitle = string.Empty;
            QualityBadge = null;
            return;
        }
        try
        {
            var t = await _core.GetTrackAsync(id);
            if (_loadedTrackId != id) return; // 期间已经切歌
            Title = t.Title;
            Subtitle = string.IsNullOrEmpty(t.AlbumTitle)
                ? string.Join(" / ", t.Artists)
                : $"{string.Join(" / ", t.Artists)} · {t.AlbumTitle}";
            QualityBadge = t.QualityBadge;
        }
        catch (CoreServiceException)
        {
            // 曲目被删除等：保持空白，等下一个播放事件。
        }
    }
}

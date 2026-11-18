namespace Lekis.Core;

/// <summary>
/// 不依赖 Rust 的假实现：UI 开发、XAML 设计器和 ViewModel 单元测试用。
/// 行为尽量和真实核心一致（例如 limit 超过 500 会报错），和 Android 的 FakeCoreBridge 保持同样的示例数据。
/// </summary>
public sealed class FakeCoreService : ICoreService
{
    private readonly List<TrackRow> _tracks;
    private readonly List<Source> _sources = [];
    private readonly Lock _gate = new();

    public FakeCoreService(IEnumerable<TrackRow>? tracks = null)
    {
        _tracks = tracks?.ToList() ?? SampleTracks();
    }

    public bool IsFake => true;
    public event EventHandler<CoreEvent>? EventReceived;
    public event EventHandler<PlaybackSnapshot>? PlaybackChanged;
    public PlaybackSnapshot Playback { get; private set; } = new();
    public string CoreVersion => "fake";

    public Task<long> AddSourceAsync(Source source)
    {
        lock (_gate)
        {
            long id = _sources.Count + 1;
            _sources.Add(source with { Id = id });
            return Task.FromResult(id);
        }
    }

    public Task<IReadOnlyList<Source>> ListSourcesAsync()
    {
        lock (_gate) return Task.FromResult<IReadOnlyList<Source>>(_sources.ToList());
    }

    public Task StartScanAsync(long sourceId)
    {
        EventReceived?.Invoke(this, new CoreEvent.ScanFinished(sourceId, _tracks.Count, 0, 0));
        EventReceived?.Invoke(this, new CoreEvent.LibraryChanged(LibraryScope.Catalog));
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<TrackRow>> ListTracksAsync(TrackSort sort, int offset, int limit)
    {
        if (limit is < 1 or > 500) throw new CoreServiceException(CoreErrorKind.InvalidArgument, "limit");
        return Task.FromResult<IReadOnlyList<TrackRow>>(_tracks.Skip(offset).Take(limit).ToList());
    }

    public Task<TrackDetail> GetTrackAsync(long trackId)
    {
        var t = _tracks.FirstOrDefault(x => x.Id == trackId)
            ?? throw new CoreServiceException(CoreErrorKind.NotFound, $"track {trackId}");
        return Task.FromResult(new TrackDetail(t.Id, t.Title, [t.ArtistLine], t.AlbumTitle, t.DurationMs, t.QualityBadge, t.ArtworkId));
    }

    public Task<IReadOnlyList<TrackRow>> SearchAsync(string text, int limit = 50) =>
        Task.FromResult<IReadOnlyList<TrackRow>>(_tracks
            .Where(t => t.Title.Contains(text, StringComparison.CurrentCultureIgnoreCase)
                     || t.ArtistLine.Contains(text, StringComparison.CurrentCultureIgnoreCase))
            .Take(limit)
            .ToList());

    public Task SetLovedAsync(long trackId, bool loved) => Task.CompletedTask;

    public void PlayTracks(IReadOnlyList<long> trackIds, int start)
    {
        if (start < 0 || start >= trackIds.Count) return;
        var id = trackIds[start];
        var track = _tracks.FirstOrDefault(t => t.Id == id);
        Update(new PlaybackSnapshot(PlaybackState.Playing, id, 0, track?.DurationMs ?? 0, trackIds.Count, start, Playback.Volume));
    }

    public void Play()
    {
        if (Playback.TrackId is not null) Update(Playback with { State = PlaybackState.Playing });
    }

    public void Pause() => Update(Playback with { State = PlaybackState.Paused });
    public void Next() { }
    public void Previous() { }
    public void Seek(long positionMs) => Update(Playback with { PositionMs = positionMs });
    public void SetRepeat(RepeatMode mode) { }
    public void SetShuffle(ShuffleMode mode) { }
    public void SetVolume(float volume) => Update(Playback with { Volume = Math.Clamp(volume, 0f, 1f) });

    public void Dispose() { }

    private void Update(PlaybackSnapshot snapshot)
    {
        Playback = snapshot;
        PlaybackChanged?.Invoke(this, snapshot);
    }

    public static List<TrackRow> SampleTracks() =>
    [
        new(1, "晴天", "周杰伦", "叶惠美", 269_000, null, "FLAC 16/44", Loved: true),
        new(2, "以父之名", "周杰伦", "叶惠美", 342_000, null, "FLAC 16/44", Loved: false),
        new(3, "Moon River", "Audrey Hepburn", null, 162_000, null, "MP3 320", Loved: false),
    ];
}

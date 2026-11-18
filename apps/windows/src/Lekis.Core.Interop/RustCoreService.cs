#if LEKIS_BINDINGS
// ============================================================================================
// ⚠ 未经编译验证（写这个文件时本机没有 uniffi-bindgen-cs）。
//   名字是按 uniffi-bindgen-cs v0.9 的命名规则写的：方法 PascalCase、record 构造参数 camelCase、
//   枚举成员 PascalCase、async 方法返回 Task<T>。第一次生成绑定后如果这里编译失败，
//   **只改这个文件**，不要改 ICoreService / Models.cs，也不要让 App 直接引用 uniffi.lekis_ffi。
//   改完删掉这段警告。对照实现：apps/android/core/bridge/.../RustCoreBridge.kt（已编译验证）。
// ============================================================================================
using System.Diagnostics;
using uniffi.lekis_ffi;

namespace Lekis.Core;

/// <summary>
/// <see cref="ICoreService"/> 的真实实现：包装 uniffi-bindgen-cs 生成的 <c>uniffi.lekis_ffi.LekisCore</c>。
/// 规则和 Android 的 RustCoreBridge 一样：
/// <list type="bullet">
/// <item>只有这个文件可以 <c>using uniffi.lekis_ffi</c>；</item>
/// <item>DTO ↔ 模型转换全部用穷举的 switch 表达式，绑定新增枚举值时编译器会提示（CS8509）；</item>
/// <item>核心在后台线程上懒加载；播放命令在单个串行队列上按调用顺序执行。</item>
/// </list>
/// </summary>
public sealed class RustCoreService : ICoreService
{
    private readonly Lazy<Task<LekisCore>> _core;
    private readonly SerialQueue _commands = new();
    private PlaybackSnapshot _playback = new();

    public RustCoreService(CoreOptions options, WindowsCredentialStore credentials)
    {
        _core = new Lazy<Task<LekisCore>>(() => Task.Run(() =>
        {
            LekisFfiMethods.InitLogging(Debugger.IsAttached ? "debug" : "info");
            var config = new CoreConfigDto(options.DataDir, options.CacheDir, options.DeviceName, PlatformDto.Windows);
            var core = MapErrors(() => new LekisCore(config, new CredentialAdapter(credentials)));
            core.AddListener(new Listener(this));
            _playback = core.PlaybackSnapshot().ToModel();
            return core;
        }));
    }

    public bool IsFake => false;
    public event EventHandler<CoreEvent>? EventReceived;
    public event EventHandler<PlaybackSnapshot>? PlaybackChanged;
    public PlaybackSnapshot Playback => Volatile.Read(ref _playback);
    public string CoreVersion => LekisFfiMethods.CoreVersion();

    // ---- 音源 ----
    public Task<long> AddSourceAsync(Source source) => Call(c => c.AddSource(source.ToDto()));

    public Task<IReadOnlyList<Source>> ListSourcesAsync() =>
        Call<IReadOnlyList<Source>>(async c => (await c.ListSources()).Select(s => s.ToModel()).ToList());

    public Task StartScanAsync(long sourceId) => Call(async c => { await c.StartScan(sourceId); return true; });

    // ---- 资料库 ----
    public Task<IReadOnlyList<TrackRow>> ListTracksAsync(TrackSort sort, int offset, int limit) =>
        Call<IReadOnlyList<TrackRow>>(async c =>
            (await c.ListTracks(sort.ToDto(), ToUInt(offset), ToUInt(limit))).Select(t => t.ToModel()).ToList());

    public Task<TrackDetail> GetTrackAsync(long trackId) => Call(async c => (await c.GetTrack(trackId)).ToModel());

    public Task<IReadOnlyList<TrackRow>> SearchAsync(string text, int limit = 50) =>
        Call<IReadOnlyList<TrackRow>>(async c =>
            (await c.Search(text, ToUInt(limit))).tracks.Select(t => t.ToModel()).ToList());

    public Task SetLovedAsync(long trackId, bool loved) => Call(async c => { await c.SetLoved(trackId, loved); return true; });

    // ---- 播放 ----
    public void PlayTracks(IReadOnlyList<long> trackIds, int start) =>
        Command(c => c.PlayTracks(trackIds.ToList(), ToUInt(start)));
    public void Play() => Command(c => c.Play());
    public void Pause() => Command(c => c.Pause());
    public void Next() => Command(c => c.Next());
    public void Previous() => Command(c => c.Previous());
    public void Seek(long positionMs) => Command(c => c.Seek((ulong)Math.Max(0, positionMs)));
    public void SetRepeat(RepeatMode mode) => Command(c => c.SetRepeat(mode.ToDto()));
    public void SetShuffle(ShuffleMode mode) => Command(c => c.SetShuffle(mode.ToDto()));
    public void SetVolume(float volume) => Command(c => c.SetVolume(Math.Clamp(volume, 0f, 1f)));

    public void Dispose()
    {
        if (_core.IsValueCreated && _core.Value.IsCompletedSuccessfully)
        {
            _core.Value.Result.Dispose();
        }
    }

    // ---- 内部 ----

    private static uint ToUInt(int v) => (uint)Math.Max(0, v);

    private async Task<T> Call<T>(Func<LekisCore, Task<T>> block)
    {
        var core = await _core.Value.ConfigureAwait(false);
        try
        {
            return await block(core).ConfigureAwait(false);
        }
        catch (CoreException.Failed e)
        {
            throw new CoreServiceException(e.kind.ToModel(), e.detail);
        }
    }

    private void Command(Action<LekisCore> block) => _commands.Enqueue(async () =>
    {
        try
        {
            var core = await _core.Value.ConfigureAwait(false);
            MapErrors(() => { block(core); return true; });
        }
        catch (CoreServiceException e)
        {
            Debug.WriteLine($"[lekis] playback command failed: {e.Kind} {e.Message}");
        }
    });

    private static T MapErrors<T>(Func<T> block)
    {
        try
        {
            return block();
        }
        catch (CoreException.Failed e)
        {
            throw new CoreServiceException(e.kind.ToModel(), e.detail);
        }
    }

    /// <summary>核心回调：在 Rust 的线程上调用，必须立刻返回。</summary>
    private sealed class Listener(RustCoreService owner) : CoreEventListener
    {
        public void OnEvent(CoreEventDto @event)
        {
            var mapped = @event.ToModel();
            if (mapped is null) return;
            var snapshot = owner.Playback;
            PlaybackSnapshot? updated = mapped switch
            {
                CoreEvent.PlaybackChanged p => snapshot with
                {
                    State = p.State, TrackId = p.TrackId, PositionMs = p.PositionMs, DurationMs = p.DurationMs,
                },
                CoreEvent.PositionTick t => snapshot with { PositionMs = t.PositionMs },
                CoreEvent.QueueChanged q => snapshot with { QueueLength = q.Length, QueueIndex = q.CurrentIndex },
                _ => null,
            };
            if (updated is not null)
            {
                Volatile.Write(ref owner._playback, updated);
                owner.PlaybackChanged?.Invoke(owner, updated);
            }
            owner.EventReceived?.Invoke(owner, mapped);
        }
    }

    private sealed class CredentialAdapter(WindowsCredentialStore inner) : CredentialStore
    {
        public string? Get(string key) => inner.Get(key);
        public bool Set(string key, string secret) => inner.Set(key, secret);
        public bool Delete(string key) => inner.Delete(key);
    }

    /// <summary>按顺序执行异步任务的简单串行队列。</summary>
    private sealed class SerialQueue
    {
        private readonly Lock _gate = new();
        private Task _tail = Task.CompletedTask;

        public void Enqueue(Func<Task> work)
        {
            lock (_gate)
            {
                _tail = _tail.ContinueWith(_ => work(), TaskScheduler.Default).Unwrap();
            }
        }
    }
}

/// <summary>DTO ↔ 模型转换。全部穷举，不要加 <c>_ =&gt;</c> 兜底分支（CoreEventDto 除外）。</summary>
internal static class Mapping
{
    private static long Sat(ulong v) => v > long.MaxValue ? long.MaxValue : (long)v;

    public static TrackSortDto ToDto(this TrackSort v) => v switch
    {
        TrackSort.Title => TrackSortDto.Title,
        TrackSort.Artist => TrackSortDto.Artist,
        TrackSort.Album => TrackSortDto.Album,
        TrackSort.RecentlyAdded => TrackSortDto.RecentlyAdded,
        TrackSort.MostPlayed => TrackSortDto.MostPlayed,
    };

    public static RepeatModeDto ToDto(this RepeatMode v) => v switch
    {
        RepeatMode.Off => RepeatModeDto.Off,
        RepeatMode.All => RepeatModeDto.All,
        RepeatMode.One => RepeatModeDto.One,
    };

    public static ShuffleModeDto ToDto(this ShuffleMode v) => v switch
    {
        ShuffleMode.Off => ShuffleModeDto.Off,
        ShuffleMode.Random => ShuffleModeDto.Random,
        ShuffleMode.Smart => ShuffleModeDto.Smart,
    };

    public static PlaybackState ToModel(this PlaybackStateDto v) => v switch
    {
        PlaybackStateDto.Idle => PlaybackState.Idle,
        PlaybackStateDto.Loading => PlaybackState.Loading,
        PlaybackStateDto.Playing => PlaybackState.Playing,
        PlaybackStateDto.Paused => PlaybackState.Paused,
        PlaybackStateDto.Buffering => PlaybackState.Buffering,
        PlaybackStateDto.Ended => PlaybackState.Ended,
    };

    public static SourceKindDto ToDto(this SourceKind v) => v switch
    {
        SourceKind.Local => SourceKindDto.Local,
        SourceKind.Smb => SourceKindDto.Smb,
        SourceKind.WebDav => SourceKindDto.WebDav,
        SourceKind.Nfs => SourceKindDto.Nfs,
        SourceKind.Sftp => SourceKindDto.Sftp,
        SourceKind.OpenSubsonic => SourceKindDto.OpenSubsonic,
        SourceKind.Jellyfin => SourceKindDto.Jellyfin,
        SourceKind.Emby => SourceKindDto.Emby,
        SourceKind.Plex => SourceKindDto.Plex,
        SourceKind.Radio => SourceKindDto.Radio,
        SourceKind.Plugin => SourceKindDto.Plugin,
    };

    public static SourceKind ToModel(this SourceKindDto v) => v switch
    {
        SourceKindDto.Local => SourceKind.Local,
        SourceKindDto.Smb => SourceKind.Smb,
        SourceKindDto.WebDav => SourceKind.WebDav,
        SourceKindDto.Nfs => SourceKind.Nfs,
        SourceKindDto.Sftp => SourceKind.Sftp,
        SourceKindDto.OpenSubsonic => SourceKind.OpenSubsonic,
        SourceKindDto.Jellyfin => SourceKind.Jellyfin,
        SourceKindDto.Emby => SourceKind.Emby,
        SourceKindDto.Plex => SourceKind.Plex,
        SourceKindDto.Radio => SourceKind.Radio,
        SourceKindDto.Plugin => SourceKind.Plugin,
    };

    public static CoreErrorKind ToModel(this ErrorKind v) => v switch
    {
        ErrorKind.NotFound => CoreErrorKind.NotFound,
        ErrorKind.InvalidArgument => CoreErrorKind.InvalidArgument,
        ErrorKind.Unsupported => CoreErrorKind.Unsupported,
        ErrorKind.NotImplemented => CoreErrorKind.NotImplemented,
        ErrorKind.Io => CoreErrorKind.Io,
        ErrorKind.Network => CoreErrorKind.Network,
        ErrorKind.Auth => CoreErrorKind.Auth,
        ErrorKind.Database => CoreErrorKind.Database,
        ErrorKind.Decode => CoreErrorKind.Decode,
        ErrorKind.Plugin => CoreErrorKind.Plugin,
        ErrorKind.PermissionDenied => CoreErrorKind.PermissionDenied,
        ErrorKind.Cancelled => CoreErrorKind.Cancelled,
        ErrorKind.RateLimited => CoreErrorKind.RateLimited,
        ErrorKind.Internal => CoreErrorKind.Internal,
    };

    public static LibraryScope ToModel(this LibraryScopeDto v) => v switch
    {
        LibraryScopeDto.Catalog => LibraryScope.Catalog,
        LibraryScopeDto.Playlists => LibraryScope.Playlists,
        LibraryScopeDto.UserState => LibraryScope.UserState,
        LibraryScopeDto.Sources => LibraryScope.Sources,
    };

    public static SourceConfigDto ToDto(this Source s) => new(
        s.Id, s.Kind.ToDto(), s.Name, s.Addresses.ToList(), s.RootPath, s.CredentialRef,
        new Dictionary<string, string>(), s.Enabled);

    public static Source ToModel(this SourceConfigDto s) => new(
        s.id, s.kind.ToModel(), s.name, s.addresses, s.rootPath, s.credentialRef, s.enabled);

    public static TrackRow ToModel(this TrackRowDto t) => new(
        t.id, t.title, t.artistLine, t.albumTitle, Sat(t.durationMs), t.artworkId, t.qualityBadge, t.loved);

    public static TrackDetail ToModel(this TrackDto t) => new(
        t.id, t.title, t.artists, t.albumTitle, Sat(t.durationMs), t.qualityBadge, t.artworkId);

    public static PlaybackSnapshot ToModel(this PlaybackSnapshotDto p) => new(
        p.state.ToModel(), p.trackId, Sat(p.positionMs), Sat(p.durationMs), (int)p.queueLen, (int?)p.queueIndex, p.volume);

    /// <summary>返回 null 表示 App 暂时不关心这个事件。</summary>
    public static CoreEvent? ToModel(this CoreEventDto e) => e switch
    {
        CoreEventDto.PlaybackChanged p => new CoreEvent.PlaybackChanged(p.state.ToModel(), p.trackId, Sat(p.positionMs), Sat(p.durationMs)),
        CoreEventDto.PositionTick t => new CoreEvent.PositionTick(Sat(t.positionMs), Sat(t.bufferedMs)),
        CoreEventDto.QueueChanged q => new CoreEvent.QueueChanged((int)q.length, (int?)q.currentIndex),
        CoreEventDto.ScanProgress s => new CoreEvent.ScanProgress(s.sourceId, Sat(s.done), s.total is { } total ? Sat(total) : null),
        CoreEventDto.ScanFinished f => new CoreEvent.ScanFinished(f.sourceId, Sat(f.added), Sat(f.updated), Sat(f.removed)),
        CoreEventDto.LibraryChanged l => new CoreEvent.LibraryChanged(l.scope.ToModel()),
        CoreEventDto.EnrichQueueChanged q => new CoreEvent.EnrichQueueChanged((int)q.pending),
        _ => null, // SyncStatus、SourceReachability 还没有 UI
    };
}
#endif

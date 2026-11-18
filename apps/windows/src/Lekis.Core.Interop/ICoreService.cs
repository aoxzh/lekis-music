namespace Lekis.Core;

/// <summary>
/// App 访问 Rust 核心的<b>唯一入口</b>（与 Android 的 CoreBridge 对应）。
/// <list type="bullet">
/// <item>所有 <c>*Async</c> 方法都可以在 UI 线程上 await（实际工作在核心自己的线程池里完成）。</item>
/// <item><see cref="EventReceived"/> 和 <see cref="PlaybackChanged"/> <b>在核心的线程上触发</b>，
///   订阅方必须自己切回 UI 线程（ViewModel 通过 IUiDispatcher）。</item>
/// <item>播放控制方法不阻塞，按调用顺序执行；失败只记日志，最终状态以事件为准。</item>
/// </list>
/// </summary>
public interface ICoreService : IDisposable
{
    /// <summary>为 true 表示这是没有加载 Rust 核心的假实现（绑定或 DLL 不存在）。设置页会显示提示。</summary>
    bool IsFake { get; }

    /// <summary>核心事件（核心线程）。</summary>
    event EventHandler<CoreEvent>? EventReceived;

    /// <summary>播放状态变化（核心线程）。</summary>
    event EventHandler<PlaybackSnapshot>? PlaybackChanged;

    /// <summary>最新的播放状态。</summary>
    PlaybackSnapshot Playback { get; }

    // ---- 音源 ----
    Task<long> AddSourceAsync(Source source);
    Task<IReadOnlyList<Source>> ListSourcesAsync();
    Task StartScanAsync(long sourceId);

    // ---- 资料库 ----
    Task<IReadOnlyList<TrackRow>> ListTracksAsync(TrackSort sort, int offset, int limit);
    Task<TrackDetail> GetTrackAsync(long trackId);
    Task<IReadOnlyList<TrackRow>> SearchAsync(string text, int limit = 50);
    Task SetLovedAsync(long trackId, bool loved);

    // ---- 播放 ----
    void PlayTracks(IReadOnlyList<long> trackIds, int start);
    void Play();
    void Pause();
    void Next();
    void Previous();
    void Seek(long positionMs);
    void SetRepeat(RepeatMode mode);
    void SetShuffle(ShuffleMode mode);
    void SetVolume(float volume);

    /// <summary>核心版本（关于页）。</summary>
    string CoreVersion { get; }
}

/// <summary>创建核心需要的路径等信息，由 App 提供。</summary>
public sealed record CoreOptions(string DataDir, string CacheDir, string DeviceName);

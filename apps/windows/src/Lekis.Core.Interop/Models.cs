namespace Lekis.Core;

/*
 * App 使用的数据模型，和 uniffi-bindgen-cs 生成的 *Dto 类型分开（与 Android 的 Models.kt 一一对应）：
 * 1. 绑定重新生成、字段改名时，只需要改 RustCoreService 里的转换代码；
 * 2. ViewModel 的单元测试可以用 FakeCoreService，不需要加载 lekis_ffi.dll。
 */

public enum TrackSort { Title, Artist, Album, RecentlyAdded, MostPlayed }

public enum PlaybackState { Idle, Loading, Playing, Paused, Buffering, Ended }

public enum RepeatMode { Off, All, One }

public enum ShuffleMode { Off, Random, Smart }

public enum SourceKind { Local, Smb, WebDav, Nfs, Sftp, OpenSubsonic, Jellyfin, Emby, Plex, Radio, Plugin }

public enum LibraryScope { Catalog, Playlists, UserState, Sources }

public sealed record TrackRow(
    long Id,
    string Title,
    string ArtistLine,
    string? AlbumTitle,
    long DurationMs,
    long? ArtworkId,
    string? QualityBadge,
    bool Loved);

public sealed record TrackDetail(
    long Id,
    string Title,
    IReadOnlyList<string> Artists,
    string? AlbumTitle,
    long DurationMs,
    string? QualityBadge,
    long? ArtworkId);

public sealed record Source(
    long? Id,
    SourceKind Kind,
    string Name,
    IReadOnlyList<string> Addresses,
    string RootPath = "",
    string? CredentialRef = null,
    bool Enabled = true);

public sealed record PlaybackSnapshot(
    PlaybackState State = PlaybackState.Idle,
    long? TrackId = null,
    long PositionMs = 0,
    long DurationMs = 0,
    int QueueLength = 0,
    int? QueueIndex = null,
    float Volume = 1f);

/// <summary>核心事件（对应 lekis-types 的 CoreEvent）。不认识的新事件会被桥接层丢弃。</summary>
public abstract record CoreEvent
{
    private CoreEvent() { }

    public sealed record PlaybackChanged(PlaybackState State, long? TrackId, long PositionMs, long DurationMs) : CoreEvent;
    public sealed record PositionTick(long PositionMs, long BufferedMs) : CoreEvent;
    public sealed record QueueChanged(int Length, int? CurrentIndex) : CoreEvent;
    public sealed record ScanProgress(long SourceId, long Done, long? Total) : CoreEvent;
    public sealed record ScanFinished(long SourceId, long Added, long Updated, long Removed) : CoreEvent;
    public sealed record LibraryChanged(LibraryScope Scope) : CoreEvent;
    public sealed record EnrichQueueChanged(int Pending) : CoreEvent;
}

public enum CoreErrorKind
{
    NotFound, InvalidArgument, Unsupported, NotImplemented, Io, Network, Auth, Database,
    Decode, Plugin, PermissionDenied, Cancelled, RateLimited, Internal,
}

/// <summary>核心错误。UI 根据 <see cref="Kind"/> 显示本地化提示，不要直接显示 <see cref="Exception.Message"/>。</summary>
public sealed class CoreServiceException(CoreErrorKind kind, string detail) : Exception(detail)
{
    public CoreErrorKind Kind { get; } = kind;
}

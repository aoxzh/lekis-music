package dev.lekis.core.bridge

/*
 * App 使用的数据模型。和 UniFFI 生成的 *Dto 类型分开，这样：
 * 1. 绑定重新生成、字段改名时，只需要改 RustCoreBridge 里的转换代码；
 * 2. ViewModel 的单元测试可以用 FakeCoreBridge，不需要加载 .so。
 */

enum class TrackSort { Title, Artist, Album, RecentlyAdded, MostPlayed }

enum class PlaybackState { Idle, Loading, Playing, Paused, Buffering, Ended }

enum class RepeatMode { Off, All, One }

enum class ShuffleMode { Off, Random, Smart }

enum class SourceKind { Local, Smb, WebDav, Nfs, Sftp, OpenSubsonic, Jellyfin, Emby, Plex, Radio, Plugin }

data class TrackRow(
    val id: Long,
    val title: String,
    val artistLine: String,
    val albumTitle: String?,
    val durationMs: Long,
    val artworkId: Long?,
    val qualityBadge: String?,
    val loved: Boolean,
)

data class TrackDetail(
    val id: Long,
    val title: String,
    val artists: List<String>,
    val albumTitle: String?,
    val durationMs: Long,
    val qualityBadge: String?,
    val artworkId: Long?,
)

data class Source(
    val id: Long?,
    val kind: SourceKind,
    val name: String,
    val addresses: List<String>,
    val rootPath: String = "",
    val credentialRef: String? = null,
    val enabled: Boolean = true,
)

data class PlaybackSnapshot(
    val state: PlaybackState = PlaybackState.Idle,
    val trackId: Long? = null,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val queueLength: Int = 0,
    val queueIndex: Int? = null,
    val volume: Float = 1f,
)

/** 核心事件（对应 lekis-types 的 CoreEvent）。不认识的新事件会被桥接层丢弃。 */
sealed interface CoreEvent {
    data class PlaybackChanged(val state: PlaybackState, val trackId: Long?, val positionMs: Long, val durationMs: Long) : CoreEvent
    data class PositionTick(val positionMs: Long, val bufferedMs: Long) : CoreEvent
    data class QueueChanged(val length: Int, val currentIndex: Int?) : CoreEvent
    data class ScanProgress(val sourceId: Long, val done: Long, val total: Long?) : CoreEvent
    data class ScanFinished(val sourceId: Long, val added: Long, val updated: Long, val removed: Long) : CoreEvent
    data class LibraryChanged(val scope: Scope) : CoreEvent {
        enum class Scope { Catalog, Playlists, UserState, Sources }
    }
    data class EnrichQueueChanged(val pending: Int) : CoreEvent
}

/** 核心错误。UI 根据 [kind] 显示本地化提示，不要直接显示 [message]。 */
class CoreBridgeException(val kind: Kind, message: String) : Exception(message) {
    enum class Kind {
        NotFound, InvalidArgument, Unsupported, NotImplemented, Io, Network, Auth, Database,
        Decode, Plugin, PermissionDenied, Cancelled, RateLimited, Internal,
    }
}

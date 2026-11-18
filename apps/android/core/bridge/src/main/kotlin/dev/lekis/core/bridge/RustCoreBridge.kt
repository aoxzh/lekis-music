package dev.lekis.core.bridge

import android.content.Context
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import uniffi.lekis_ffi.CoreConfigDto
import uniffi.lekis_ffi.CoreEventDto
import uniffi.lekis_ffi.CoreEventListener
import uniffi.lekis_ffi.CoreException
import uniffi.lekis_ffi.ErrorKind
import uniffi.lekis_ffi.LekisCore
import uniffi.lekis_ffi.LibraryScopeDto
import uniffi.lekis_ffi.PlatformDto
import uniffi.lekis_ffi.PlaybackSnapshotDto
import uniffi.lekis_ffi.PlaybackStateDto
import uniffi.lekis_ffi.RepeatModeDto
import uniffi.lekis_ffi.ShuffleModeDto
import uniffi.lekis_ffi.SourceConfigDto
import uniffi.lekis_ffi.SourceKindDto
import uniffi.lekis_ffi.TrackDto
import uniffi.lekis_ffi.TrackRowDto
import uniffi.lekis_ffi.TrackSortDto

/**
 * [CoreBridge] 的真实实现：包装 UniFFI 生成的 `uniffi.lekis_ffi.LekisCore`。
 *
 * 规则：
 * - **只有这个文件**可以 import `uniffi.lekis_ffi.*`。App 的其他代码只认 [Models.kt] 里的类型；
 * - 所有 DTO ↔ 模型的转换都写成穷举的 `when`，绑定里新增枚举值时这里会编译失败，而不是悄悄出错；
 * - 核心在 IO 线程上懒加载（打开数据库要几十毫秒），第一次调用会等它初始化完成；
 * - 播放控制在一个单线程调度器上按顺序执行，保证 play/pause/seek 的顺序和调用顺序一致。
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RustCoreBridge(context: Context) : CoreBridge {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val commandDispatcher = Dispatchers.IO.limitedParallelism(1)

    private val _events = MutableSharedFlow<CoreEvent>(
        extraBufferCapacity = 64,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    override val events: SharedFlow<CoreEvent> = _events.asSharedFlow()

    private val _playback = MutableStateFlow(PlaybackSnapshot())
    override val playback: StateFlow<PlaybackSnapshot> = _playback.asStateFlow()

    private val core: Deferred<LekisCore> = scope.async {
        uniffi.lekis_ffi.initLogging(if (BuildConfig.DEBUG) "debug" else "info")
        val config = CoreConfigDto(
            dataDir = appContext.filesDir.resolve("lekis").absolutePath,
            cacheDir = appContext.cacheDir.resolve("lekis").absolutePath,
            deviceName = Build.MODEL ?: "Android",
            platform = PlatformDto.ANDROID,
        )
        val created = mapErrors { LekisCore(config, AndroidCredentialStore(appContext)) }
        created.addListener(Listener())
        _playback.value = created.playbackSnapshot().toModel()
        created
    }

    // ---- 音源 ----

    override suspend fun addSource(source: Source): Long = call { addSource(source.toDto()) }

    override suspend fun listSources(): List<Source> = call { listSources().map { it.toModel() } }

    override suspend fun startScan(sourceId: Long) = call { startScan(sourceId) }

    // ---- 资料库 ----

    override suspend fun listTracks(sort: TrackSort, offset: Int, limit: Int): List<TrackRow> = call {
        listTracks(sort.toDto(), offset.toNonNegativeUInt(), limit.toNonNegativeUInt()).map { it.toModel() }
    }

    override suspend fun getTrack(trackId: Long): TrackDetail = call { getTrack(trackId).toModel() }

    override suspend fun search(text: String, limit: Int): List<TrackRow> = call {
        search(text, limit.toNonNegativeUInt()).tracks.map { it.toModel() }
    }

    override suspend fun setLoved(trackId: Long, loved: Boolean) = call { setLoved(trackId, loved) }

    // ---- 播放 ----

    override fun playTracks(trackIds: List<Long>, start: Int) =
        command { playTracks(trackIds, start.toNonNegativeUInt()) }

    override fun play() = command { play() }
    override fun pause() = command { pause() }
    override fun next() = command { next() }
    override fun previous() = command { previous() }
    override fun seek(positionMs: Long) = command { seek(positionMs.coerceAtLeast(0).toULong()) }
    override fun setRepeat(mode: RepeatMode) = command { setRepeat(mode.toDto()) }
    override fun setShuffle(mode: ShuffleMode) = command { setShuffle(mode.toDto()) }

    override fun coreVersion(): String = uniffi.lekis_ffi.coreVersion()

    // ---- 内部 ----

    /** 等核心就绪后调用，并把 [CoreException] 转成 [CoreBridgeException]。 */
    private suspend inline fun <T> call(crossinline block: suspend LekisCore.() -> T): T {
        val c = core.await()
        return mapErrors { c.block() }
    }

    /** 播放命令：不阻塞调用方，按调用顺序在单线程上执行，失败只记日志（状态由事件回传）。 */
    private fun command(block: LekisCore.() -> Unit) {
        scope.launch(commandDispatcher) {
            try {
                mapErrors { core.await().block() }
            } catch (e: CoreBridgeException) {
                Log.w(TAG, "playback command failed: ${e.kind}", e)
            }
        }
    }

    private inline fun <T> mapErrors(block: () -> T): T =
        try {
            block()
        } catch (e: CoreException.Failed) {
            throw CoreBridgeException(e.kind.toModel(), e.detail)
        }

    /** 核心回调：在 Rust 的线程上调用，必须立刻返回，不能阻塞。 */
    private inner class Listener : CoreEventListener {
        override fun onEvent(event: CoreEventDto) {
            val mapped = event.toModel() ?: return
            when (mapped) {
                is CoreEvent.PlaybackChanged -> _playback.update {
                    it.copy(
                        state = mapped.state,
                        trackId = mapped.trackId,
                        positionMs = mapped.positionMs,
                        durationMs = mapped.durationMs,
                    )
                }
                is CoreEvent.PositionTick -> _playback.update { it.copy(positionMs = mapped.positionMs) }
                is CoreEvent.QueueChanged -> _playback.update {
                    it.copy(queueLength = mapped.length, queueIndex = mapped.currentIndex)
                }
                else -> Unit
            }
            _events.tryEmit(mapped)
        }
    }

    private companion object {
        const val TAG = "LekisCore"
    }
}

// ---------------------------------------------------------------------------
// DTO ↔ 模型转换。全部穷举，不要用 `else` 分支，也不要用 `valueOf(name)`。
// ---------------------------------------------------------------------------

private fun Int.toNonNegativeUInt(): UInt = coerceAtLeast(0).toUInt()

private fun ULong.toLongSaturated(): Long = if (this > Long.MAX_VALUE.toULong()) Long.MAX_VALUE else toLong()

private fun TrackSort.toDto() = when (this) {
    TrackSort.Title -> TrackSortDto.TITLE
    TrackSort.Artist -> TrackSortDto.ARTIST
    TrackSort.Album -> TrackSortDto.ALBUM
    TrackSort.RecentlyAdded -> TrackSortDto.RECENTLY_ADDED
    TrackSort.MostPlayed -> TrackSortDto.MOST_PLAYED
}

private fun RepeatMode.toDto() = when (this) {
    RepeatMode.Off -> RepeatModeDto.OFF
    RepeatMode.All -> RepeatModeDto.ALL
    RepeatMode.One -> RepeatModeDto.ONE
}

private fun ShuffleMode.toDto() = when (this) {
    ShuffleMode.Off -> ShuffleModeDto.OFF
    ShuffleMode.Random -> ShuffleModeDto.RANDOM
    ShuffleMode.Smart -> ShuffleModeDto.SMART
}

private fun PlaybackStateDto.toModel() = when (this) {
    PlaybackStateDto.IDLE -> PlaybackState.Idle
    PlaybackStateDto.LOADING -> PlaybackState.Loading
    PlaybackStateDto.PLAYING -> PlaybackState.Playing
    PlaybackStateDto.PAUSED -> PlaybackState.Paused
    PlaybackStateDto.BUFFERING -> PlaybackState.Buffering
    PlaybackStateDto.ENDED -> PlaybackState.Ended
}

private fun SourceKind.toDto() = when (this) {
    SourceKind.Local -> SourceKindDto.LOCAL
    SourceKind.Smb -> SourceKindDto.SMB
    SourceKind.WebDav -> SourceKindDto.WEB_DAV
    SourceKind.Nfs -> SourceKindDto.NFS
    SourceKind.Sftp -> SourceKindDto.SFTP
    SourceKind.OpenSubsonic -> SourceKindDto.OPEN_SUBSONIC
    SourceKind.Jellyfin -> SourceKindDto.JELLYFIN
    SourceKind.Emby -> SourceKindDto.EMBY
    SourceKind.Plex -> SourceKindDto.PLEX
    SourceKind.Radio -> SourceKindDto.RADIO
    SourceKind.Plugin -> SourceKindDto.PLUGIN
}

private fun SourceKindDto.toModel() = when (this) {
    SourceKindDto.LOCAL -> SourceKind.Local
    SourceKindDto.SMB -> SourceKind.Smb
    SourceKindDto.WEB_DAV -> SourceKind.WebDav
    SourceKindDto.NFS -> SourceKind.Nfs
    SourceKindDto.SFTP -> SourceKind.Sftp
    SourceKindDto.OPEN_SUBSONIC -> SourceKind.OpenSubsonic
    SourceKindDto.JELLYFIN -> SourceKind.Jellyfin
    SourceKindDto.EMBY -> SourceKind.Emby
    SourceKindDto.PLEX -> SourceKind.Plex
    SourceKindDto.RADIO -> SourceKind.Radio
    SourceKindDto.PLUGIN -> SourceKind.Plugin
}

private fun ErrorKind.toModel() = when (this) {
    ErrorKind.NOT_FOUND -> CoreBridgeException.Kind.NotFound
    ErrorKind.INVALID_ARGUMENT -> CoreBridgeException.Kind.InvalidArgument
    ErrorKind.UNSUPPORTED -> CoreBridgeException.Kind.Unsupported
    ErrorKind.NOT_IMPLEMENTED -> CoreBridgeException.Kind.NotImplemented
    ErrorKind.IO -> CoreBridgeException.Kind.Io
    ErrorKind.NETWORK -> CoreBridgeException.Kind.Network
    ErrorKind.AUTH -> CoreBridgeException.Kind.Auth
    ErrorKind.DATABASE -> CoreBridgeException.Kind.Database
    ErrorKind.DECODE -> CoreBridgeException.Kind.Decode
    ErrorKind.PLUGIN -> CoreBridgeException.Kind.Plugin
    ErrorKind.PERMISSION_DENIED -> CoreBridgeException.Kind.PermissionDenied
    ErrorKind.CANCELLED -> CoreBridgeException.Kind.Cancelled
    ErrorKind.RATE_LIMITED -> CoreBridgeException.Kind.RateLimited
    ErrorKind.INTERNAL -> CoreBridgeException.Kind.Internal
}

private fun LibraryScopeDto.toModel() = when (this) {
    LibraryScopeDto.CATALOG -> CoreEvent.LibraryChanged.Scope.Catalog
    LibraryScopeDto.PLAYLISTS -> CoreEvent.LibraryChanged.Scope.Playlists
    LibraryScopeDto.USER_STATE -> CoreEvent.LibraryChanged.Scope.UserState
    LibraryScopeDto.SOURCES -> CoreEvent.LibraryChanged.Scope.Sources
}

private fun Source.toDto() = SourceConfigDto(
    id = id,
    kind = kind.toDto(),
    name = name,
    addresses = addresses,
    rootPath = rootPath,
    credentialRef = credentialRef,
    options = emptyMap(),
    enabled = enabled,
)

private fun SourceConfigDto.toModel() = Source(
    id = id,
    kind = kind.toModel(),
    name = name,
    addresses = addresses,
    rootPath = rootPath,
    credentialRef = credentialRef,
    enabled = enabled,
)

private fun TrackRowDto.toModel() = TrackRow(
    id = id,
    title = title,
    artistLine = artistLine,
    albumTitle = albumTitle,
    durationMs = durationMs.toLongSaturated(),
    artworkId = artworkId,
    qualityBadge = qualityBadge,
    loved = loved,
)

private fun TrackDto.toModel() = TrackDetail(
    id = id,
    title = title,
    artists = artists,
    albumTitle = albumTitle,
    durationMs = durationMs.toLongSaturated(),
    qualityBadge = qualityBadge,
    artworkId = artworkId,
)

private fun PlaybackSnapshotDto.toModel() = PlaybackSnapshot(
    state = state.toModel(),
    trackId = trackId,
    positionMs = positionMs.toLongSaturated(),
    durationMs = durationMs.toLongSaturated(),
    queueLength = queueLen.toInt(),
    queueIndex = queueIndex?.toInt(),
    volume = volume,
)

/** 返回 null 表示 App 暂时不关心这个事件（SyncStatus、SourceReachability 还没有 UI）。 */
private fun CoreEventDto.toModel(): CoreEvent? = when (this) {
    is CoreEventDto.PlaybackChanged -> CoreEvent.PlaybackChanged(
        state = state.toModel(),
        trackId = trackId,
        positionMs = positionMs.toLongSaturated(),
        durationMs = durationMs.toLongSaturated(),
    )
    is CoreEventDto.PositionTick -> CoreEvent.PositionTick(positionMs.toLongSaturated(), bufferedMs.toLongSaturated())
    is CoreEventDto.QueueChanged -> CoreEvent.QueueChanged(length.toInt(), currentIndex?.toInt())
    is CoreEventDto.ScanProgress -> CoreEvent.ScanProgress(sourceId, done.toLongSaturated(), total?.toLongSaturated())
    is CoreEventDto.ScanFinished -> CoreEvent.ScanFinished(
        sourceId,
        added.toLongSaturated(),
        updated.toLongSaturated(),
        removed.toLongSaturated(),
    )
    is CoreEventDto.LibraryChanged -> CoreEvent.LibraryChanged(scope.toModel())
    is CoreEventDto.EnrichQueueChanged -> CoreEvent.EnrichQueueChanged(pending.toInt())
    is CoreEventDto.SyncStatus -> null
    is CoreEventDto.SourceReachability -> null
}

package dev.lekis.core.bridge

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/**
 * 不依赖 Rust 的假实现：ViewModel 单元测试和 Compose 预览用。
 * 行为尽量和真实核心一致（例如 limit 超过 500 会报错）。
 */
class FakeCoreBridge(
    private val tracks: List<TrackRow> = sampleTracks(),
) : CoreBridge {
    private val _events = MutableSharedFlow<CoreEvent>(extraBufferCapacity = 64)
    override val events: SharedFlow<CoreEvent> = _events
    private val _playback = MutableStateFlow(PlaybackSnapshot())
    override val playback: StateFlow<PlaybackSnapshot> = _playback
    private val sources = mutableListOf<Source>()

    override suspend fun addSource(source: Source): Long {
        val id = sources.size + 1L
        sources += source.copy(id = id)
        return id
    }

    override suspend fun listSources(): List<Source> = sources.toList()

    override suspend fun startScan(sourceId: Long) {
        _events.emit(CoreEvent.ScanFinished(sourceId, added = tracks.size.toLong(), updated = 0, removed = 0))
    }

    override suspend fun listTracks(sort: TrackSort, offset: Int, limit: Int): List<TrackRow> {
        if (limit !in 1..500) throw CoreBridgeException(CoreBridgeException.Kind.InvalidArgument, "limit")
        return tracks.drop(offset).take(limit)
    }

    override suspend fun getTrack(trackId: Long): TrackDetail {
        val t = tracks.firstOrNull { it.id == trackId }
            ?: throw CoreBridgeException(CoreBridgeException.Kind.NotFound, "track $trackId")
        return TrackDetail(t.id, t.title, listOf(t.artistLine), t.albumTitle, t.durationMs, t.qualityBadge, t.artworkId)
    }

    override suspend fun search(text: String, limit: Int): List<TrackRow> =
        tracks.filter { it.title.contains(text, ignoreCase = true) || it.artistLine.contains(text, ignoreCase = true) }
            .take(limit)

    override suspend fun setLoved(trackId: Long, loved: Boolean) {}

    override fun playTracks(trackIds: List<Long>, start: Int) {
        val id = trackIds.getOrNull(start) ?: return
        val track = tracks.firstOrNull { it.id == id }
        _playback.update {
            it.copy(state = PlaybackState.Playing, trackId = id, positionMs = 0, durationMs = track?.durationMs ?: 0,
                queueLength = trackIds.size, queueIndex = start)
        }
    }

    override fun play() = _playback.update { if (it.trackId != null) it.copy(state = PlaybackState.Playing) else it }
    override fun pause() = _playback.update { it.copy(state = PlaybackState.Paused) }
    override fun next() {}
    override fun previous() {}
    override fun seek(positionMs: Long) = _playback.update { it.copy(positionMs = positionMs) }
    override fun setRepeat(mode: RepeatMode) {}
    override fun setShuffle(mode: ShuffleMode) {}
    override fun coreVersion(): String = "fake"

    companion object {
        fun sampleTracks() = listOf(
            TrackRow(1, "晴天", "周杰伦", "叶惠美", 269_000, null, "FLAC 16/44", loved = true),
            TrackRow(2, "以父之名", "周杰伦", "叶惠美", 342_000, null, "FLAC 16/44", loved = false),
            TrackRow(3, "Moon River", "Audrey Hepburn", null, 162_000, null, "MP3 320", loved = false),
        )
    }
}

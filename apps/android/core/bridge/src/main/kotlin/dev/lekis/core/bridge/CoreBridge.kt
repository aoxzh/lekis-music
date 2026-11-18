package dev.lekis.core.bridge

import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * App 访问 Rust 核心的**唯一入口**（docs/ARCHITECTURE.md 第 7 节）。
 *
 * - 所有 `suspend` 方法都可以在主线程上调用（实际工作在核心自己的线程池里完成）；
 * - 播放控制方法是非阻塞的，但 UI **不要**直接调用它们——请通过 MediaController，
 *   只有 `playback/CorePlayer` 可以调用（这样系统媒体会话的状态才一致）。
 */
interface CoreBridge {
    /** 核心事件流。 */
    val events: SharedFlow<CoreEvent>

    /** 播放状态（由 PlaybackChanged / PositionTick / QueueChanged 事件维护）。 */
    val playback: StateFlow<PlaybackSnapshot>

    // ---- 音源 ----
    suspend fun addSource(source: Source): Long
    suspend fun listSources(): List<Source>
    suspend fun startScan(sourceId: Long)

    // ---- 资料库 ----
    suspend fun listTracks(sort: TrackSort, offset: Int, limit: Int): List<TrackRow>
    suspend fun getTrack(trackId: Long): TrackDetail
    suspend fun search(text: String, limit: Int = 50): List<TrackRow>
    suspend fun setLoved(trackId: Long, loved: Boolean)

    // ---- 播放（只给 CorePlayer 用）----
    fun playTracks(trackIds: List<Long>, start: Int)
    fun play()
    fun pause()
    fun next()
    fun previous()
    fun seek(positionMs: Long)
    fun setRepeat(mode: RepeatMode)
    fun setShuffle(mode: ShuffleMode)

    /** 核心版本（关于页）。 */
    fun coreVersion(): String
}

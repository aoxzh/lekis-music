package dev.lekis.music.feature.nowplaying

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.lekis.core.bridge.CoreBridge
import dev.lekis.core.bridge.PlaybackSnapshot
import dev.lekis.core.bridge.PlaybackState
import dev.lekis.core.bridge.TrackDetail
import dev.lekis.music.playback.PlaybackConnection
import javax.inject.Inject
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.stateIn

data class NowPlayingUiState(
    val snapshot: PlaybackSnapshot = PlaybackSnapshot(),
    val track: TrackDetail? = null,
) {
    val isPlaying get() = snapshot.state == PlaybackState.Playing
}

/**
 * 正在播放页 + 迷你播放条共用。
 *
 * TODO(4.5.3)：
 * - 封面取色 → 流动渐变背景（核心返回 Palette，UI 用 RuntimeShader / AGSL 实现，低电量降级为静态模糊）；
 * - 歌词页：逐字高亮、当前行放大、非当前行模糊、弹簧滚动（LekisTokens.Motion.lyricsScroll）；
 * - 音质标签、比特完美标识；收藏、循环、随机按钮。
 */
@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class NowPlayingViewModel @Inject constructor(
    private val core: CoreBridge,
    private val playback: PlaybackConnection,
) : ViewModel() {

    private val track = core.playback
        .map { it.trackId }
        .distinctUntilChanged()
        .flatMapLatest { id ->
            if (id == null) {
                flowOf<TrackDetail?>(null)
            } else {
                flow<TrackDetail?> { emit(runCatching { core.getTrack(id) }.getOrNull()) }
            }
        }

    val state: StateFlow<NowPlayingUiState> = combine(core.playback, track) { snap, t -> NowPlayingUiState(snap, t) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), NowPlayingUiState())

    fun togglePlayPause() = playback.togglePlayPause()
    fun next() = playback.next()
    fun previous() = playback.previous()
    fun seekTo(positionMs: Long) = playback.seekTo(positionMs)
}

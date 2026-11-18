package dev.lekis.music.feature.library

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.lekis.core.bridge.CoreBridge
import dev.lekis.core.bridge.CoreEvent
import dev.lekis.core.bridge.TrackRow
import dev.lekis.core.bridge.TrackSort
import dev.lekis.music.playback.PlaybackConnection
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

data class LibraryUiState(
    val sort: TrackSort = TrackSort.Title,
    val tracks: List<TrackRow> = emptyList(),
    val endReached: Boolean = false,
)

/**
 * 资料库（歌曲视图）。
 *
 * 分页：每次取 [PAGE_SIZE] 条，滚动到底部时 [loadMore]。10 万首也只在内存里保留已经滚过的部分。
 * TODO：换成 Paging 3（PagingSource 包装 CoreBridge.listTracks），支持跳跃滚动和字母索引条。
 * TODO：专辑 / 艺人 / 歌单 / 文件夹 视图。
 */
@HiltViewModel
class LibraryViewModel @Inject constructor(
    private val core: CoreBridge,
    private val playback: PlaybackConnection,
) : ViewModel() {

    private val _state = MutableStateFlow(LibraryUiState())
    val state: StateFlow<LibraryUiState> = _state.asStateFlow()
    private var loading = false

    init {
        reload()
        core.events.filterIsInstance<CoreEvent.LibraryChanged>()
            .onEach { reload() }
            .launchIn(viewModelScope)
    }

    fun setSort(sort: TrackSort) {
        _state.value = LibraryUiState(sort = sort)
        reload()
    }

    fun reload() {
        _state.value = _state.value.copy(tracks = emptyList(), endReached = false)
        loadMore()
    }

    fun loadMore() {
        val s = _state.value
        if (loading || s.endReached) return
        loading = true
        viewModelScope.launch {
            runCatching { core.listTracks(s.sort, s.tracks.size, PAGE_SIZE) }
                .onSuccess { page ->
                    _state.value = _state.value.copy(tracks = _state.value.tracks + page, endReached = page.size < PAGE_SIZE)
                }
            loading = false
        }
    }

    fun play(index: Int) {
        // TODO：队列应该是"整个资料库按当前排序"，而不是只有已加载的部分——由核心提供"按查询播放"的接口。
        playback.playTracks(_state.value.tracks.map { it.id }, index)
    }

    companion object {
        const val PAGE_SIZE = 200
    }
}

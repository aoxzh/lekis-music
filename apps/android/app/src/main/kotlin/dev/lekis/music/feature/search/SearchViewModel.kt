package dev.lekis.music.feature.search

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.lekis.core.bridge.CoreBridge
import dev.lekis.core.bridge.TrackRow
import dev.lekis.music.playback.PlaybackConnection
import javax.inject.Inject
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.ExperimentalCoroutinesApi

/**
 * 搜索（LIB-07）：每次输入后 120ms 查询一次，核心保证 ≤ 50ms 返回。
 * TODO：专辑 / 艺人分组；"在线"分区（来自音源插件，PLG-08）。
 */
@OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
@HiltViewModel
class SearchViewModel @Inject constructor(
    private val core: CoreBridge,
    private val playback: PlaybackConnection,
) : ViewModel() {

    val query = MutableStateFlow("")

    val results: StateFlow<List<TrackRow>> = query
        .debounce(120)
        .mapLatest { q -> if (q.isBlank()) emptyList() else runCatching { core.search(q) }.getOrDefault(emptyList()) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    fun play(index: Int) = playback.playTracks(results.value.map { it.id }, index)
}

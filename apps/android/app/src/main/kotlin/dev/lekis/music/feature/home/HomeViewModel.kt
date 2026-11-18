package dev.lekis.music.feature.home

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

data class HomeUiState(
    val loading: Boolean = true,
    val hasSources: Boolean = false,
    val recentlyAdded: List<TrackRow> = emptyList(),
    val scanning: Boolean = false,
    // TODO(DIS-04)：继续播放、每日混音、往年今日、未补全提示
)

@HiltViewModel
class HomeViewModel @Inject constructor(
    private val core: CoreBridge,
    private val playback: PlaybackConnection,
) : ViewModel() {

    private val _state = MutableStateFlow(HomeUiState())
    val state: StateFlow<HomeUiState> = _state.asStateFlow()

    init {
        refresh()
        core.events.onEach { event ->
            when (event) {
                is CoreEvent.ScanProgress -> _state.value = _state.value.copy(scanning = true)
                is CoreEvent.ScanFinished -> {
                    _state.value = _state.value.copy(scanning = false)
                    refresh()
                }
                is CoreEvent.LibraryChanged -> refresh()
                else -> Unit
            }
        }.launchIn(viewModelScope)
    }

    fun refresh() = viewModelScope.launch {
        runCatching {
            val sources = core.listSources()
            val recent = if (sources.isEmpty()) emptyList() else core.listTracks(TrackSort.RecentlyAdded, 0, 30)
            _state.value = _state.value.copy(loading = false, hasSources = sources.isNotEmpty(), recentlyAdded = recent)
        }.onFailure { _state.value = _state.value.copy(loading = false) }
    }

    fun play(track: TrackRow) {
        val list = _state.value.recentlyAdded
        playback.playTracks(list.map { it.id }, list.indexOf(track).coerceAtLeast(0))
    }
}

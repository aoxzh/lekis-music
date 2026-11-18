package dev.lekis.music.feature.sources

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.lekis.core.bridge.CoreBridge
import dev.lekis.core.bridge.Source
import dev.lekis.core.bridge.SourceKind
import dev.lekis.music.common.userMessage
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class SourcesUiState(
    val sources: List<Source> = emptyList(),
    val errorRes: Int? = null,
)

/**
 * 音源管理（REQUIREMENTS 3.1，SRC-01~15）。
 *
 * TODO：
 * - 局域网自动发现 NAS（核心提供 discover() 事件流：mDNS / WS-Discovery / SSDP）；
 * - 本机文件夹：Android 上 SAF 返回的是 content:// URI，Rust 的 LocalVfs 需要文件路径。
 *   方案（待 ADR）：有 READ_MEDIA_AUDIO 权限时直接用 /storage/emulated/0/Music 这类路径；
 *   SD 卡 / USB 盘走 SAF，由平台通过回调接口提供读取能力；
 * - 服务器登录（Navidrome / Jellyfin / Plex 授权流程）。
 */
@HiltViewModel
class SourcesViewModel @Inject constructor(private val core: CoreBridge) : ViewModel() {

    private val _state = MutableStateFlow(SourcesUiState())
    val state: StateFlow<SourcesUiState> = _state.asStateFlow()

    init {
        refresh()
    }

    fun refresh() = viewModelScope.launch {
        runCatching { core.listSources() }.onSuccess { _state.value = _state.value.copy(sources = it) }
    }

    /** 添加一个文件系统类音源并立即开始扫描。 */
    fun addFilesystemSource(kind: SourceKind, name: String, address: String) = viewModelScope.launch {
        runCatching {
            val id = core.addSource(Source(id = null, kind = kind, name = name, addresses = listOf(address)))
            core.startScan(id)
        }.onFailure { e ->
            _state.value = _state.value.copy(errorRes = e.userMessage())
        }
        refresh()
    }
}

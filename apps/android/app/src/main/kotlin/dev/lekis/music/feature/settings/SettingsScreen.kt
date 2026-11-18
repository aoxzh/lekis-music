package dev.lekis.music.feature.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.lekis.core.bridge.CoreBridge
import dev.lekis.designsystem.LekisTokens
import dev.lekis.music.R
import javax.inject.Inject

@HiltViewModel
class SettingsViewModel @Inject constructor(private val core: CoreBridge) : ViewModel() {
    val coreVersion: String = runCatching { core.coreVersion() }.getOrDefault("?")
}

/**
 * 设置。TODO：主题、播放（ReplayGain、淡入淡出、EQ、比特完美）、补全（自动应用阈值、写回原文件）、
 * 同步、插件、Scrobble、存储管理、诊断日志导出。
 */
@Composable
fun SettingsScreen(onOpenSources: () -> Unit, vm: SettingsViewModel = hiltViewModel()) {
    Column(Modifier.fillMaxSize()) {
        Text(
            stringResource(R.string.tab_settings),
            style = MaterialTheme.typography.displaySmall,
            modifier = Modifier.padding(LekisTokens.Spacing.pageGutter),
        )
        ListItem(
            headlineContent = { Text(stringResource(R.string.sources_title)) },
            modifier = Modifier.clickable(onClick = onOpenSources),
        )
        ListItem(
            headlineContent = { Text(stringResource(R.string.settings_about)) },
            supportingContent = { Text(stringResource(R.string.settings_core_version, vm.coreVersion)) },
        )
    }
}

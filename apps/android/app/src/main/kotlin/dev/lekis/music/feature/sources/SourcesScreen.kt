package dev.lekis.music.feature.sources

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.lekis.core.bridge.SourceKind
import dev.lekis.designsystem.LekisTokens
import dev.lekis.music.R

/** 原型版本：手动输入地址。正式版本是"自动发现 + 向导"。 */
@Composable
fun SourcesScreen(vm: SourcesViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
    var address by remember { mutableStateOf("/storage/emulated/0/Music") }

    Column(
        Modifier.fillMaxSize().padding(LekisTokens.Spacing.pageGutter),
        verticalArrangement = Arrangement.spacedBy(LekisTokens.Spacing.md),
    ) {
        Text(stringResource(R.string.sources_title), style = MaterialTheme.typography.displaySmall)
        state.sources.forEach { s ->
            ListItem(headlineContent = { Text(s.name) }, supportingContent = { Text(s.addresses.firstOrNull().orEmpty()) })
        }
        OutlinedTextField(value = address, onValueChange = { address = it }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedButton(onClick = { vm.addFilesystemSource(SourceKind.Local, "Music", address) }, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.sources_add_local))
        }
        OutlinedButton(onClick = { vm.addFilesystemSource(SourceKind.Smb, "NAS", address) }, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.sources_add_smb))
        }
        OutlinedButton(onClick = { vm.addFilesystemSource(SourceKind.WebDav, "WebDAV", address) }, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.sources_add_webdav))
        }
        state.errorRes?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
    }
}

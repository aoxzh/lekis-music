package dev.lekis.music.feature.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.lekis.designsystem.LekisTokens
import dev.lekis.designsystem.component.TrackListItem
import dev.lekis.music.R

@Composable
fun HomeScreen(onAddSource: () -> Unit, vm: HomeViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
    when {
        state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        !state.hasSources -> EmptyHome(onAddSource)
        else -> LazyColumn(Modifier.fillMaxSize()) {
            item {
                Text(
                    stringResource(R.string.tab_home),
                    style = MaterialTheme.typography.displaySmall,
                    modifier = Modifier.padding(LekisTokens.Spacing.pageGutter),
                )
                if (state.scanning) LinearProgressIndicator(Modifier.padding(horizontal = LekisTokens.Spacing.pageGutter))
            }
            items(state.recentlyAdded, key = { it.id }) { t ->
                TrackListItem(
                    title = t.title,
                    subtitle = listOfNotNull(t.artistLine, t.albumTitle).joinToString(" · "),
                    artworkPath = null, // TODO：核心提供缩略图路径（artwork_id → 本地文件）
                    qualityBadge = t.qualityBadge,
                    loved = t.loved,
                    onClick = { vm.play(t) },
                )
            }
        }
    }
}

@Composable
private fun EmptyHome(onAddSource: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(LekisTokens.Spacing.xxl),
        verticalArrangement = Arrangement.spacedBy(LekisTokens.Spacing.lg, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(stringResource(R.string.home_empty_title), style = MaterialTheme.typography.headlineMedium)
        Text(
            stringResource(R.string.home_empty_body),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(onClick = onAddSource) { Text(stringResource(R.string.action_add_source)) }
    }
}

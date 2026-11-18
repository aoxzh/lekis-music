package dev.lekis.music.feature.library

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.lekis.designsystem.LekisTokens
import dev.lekis.designsystem.component.TrackListItem
import dev.lekis.music.R

@Composable
fun LibraryScreen(vm: LibraryViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()

    // 距离底部 50 行时加载下一页
    val nearEnd by remember {
        derivedStateOf {
            val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= listState.layoutInfo.totalItemsCount - 50
        }
    }
    LaunchedEffect(nearEnd) { if (nearEnd) vm.loadMore() }

    LazyColumn(Modifier.fillMaxSize(), state = listState) {
        item {
            Text(
                stringResource(R.string.library_tracks),
                style = MaterialTheme.typography.displaySmall,
                modifier = Modifier.padding(LekisTokens.Spacing.pageGutter),
            )
        }
        itemsIndexed(state.tracks, key = { _, t -> t.id }) { index, t ->
            TrackListItem(
                title = t.title,
                subtitle = listOfNotNull(t.artistLine.ifEmpty { null }, t.albumTitle).joinToString(" · "),
                artworkPath = null,
                qualityBadge = t.qualityBadge,
                loved = t.loved,
                onClick = { vm.play(index) },
            )
        }
    }
}

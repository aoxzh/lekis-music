package dev.lekis.music.feature.search

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.lekis.designsystem.LekisTokens
import dev.lekis.designsystem.component.TrackListItem
import dev.lekis.music.R

@Composable
fun SearchScreen(vm: SearchViewModel = hiltViewModel()) {
    val query by vm.query.collectAsStateWithLifecycle()
    val results by vm.results.collectAsStateWithLifecycle()
    Column(Modifier.fillMaxSize()) {
        OutlinedTextField(
            value = query,
            onValueChange = { vm.query.value = it },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            placeholder = { Text(stringResource(R.string.search_hint)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(LekisTokens.Spacing.pageGutter),
        )
        LazyColumn(Modifier.fillMaxSize()) {
            itemsIndexed(results, key = { _, t -> t.id }) { index, t ->
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
}

package dev.lekis.music.feature.nowplaying

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.lekis.designsystem.LekisTokens
import dev.lekis.designsystem.component.Artwork
import dev.lekis.music.R
import dev.lekis.music.common.formatDuration

@Composable
fun NowPlayingScreen(onCollapse: () -> Unit, vm: NowPlayingViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
    val track = state.track
    Column(
        Modifier
            .fillMaxSize()
            // TODO：动态取色渐变背景
            .background(MaterialTheme.colorScheme.background)
            .padding(horizontal = LekisTokens.Spacing.xl),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        IconButton(onClick = onCollapse, modifier = Modifier.align(Alignment.Start)) {
            Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null)
        }
        Spacer(Modifier.height(LekisTokens.Spacing.xl))
        Surface(
            shape = RoundedCornerShape(LekisTokens.Radius.artworkNowPlaying),
            tonalElevation = 6.dp,
            modifier = Modifier.fillMaxWidth().aspectRatio(1f),
        ) {
            // TODO：大尺寸封面（ArtworkSize.Large），切歌时共享元素转场
        }
        Spacer(Modifier.height(LekisTokens.Spacing.xxl))
        Text(
            track?.title ?: stringResource(R.string.now_playing_nothing),
            style = MaterialTheme.typography.titleLarge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            track?.artists?.joinToString(" / ").orEmpty(),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(LekisTokens.Spacing.lg))
        val duration = state.snapshot.durationMs.coerceAtLeast(1)
        Slider(
            value = state.snapshot.positionMs.toFloat() / duration,
            onValueChange = { vm.seekTo((it * duration).toLong()) },
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(formatDuration(state.snapshot.positionMs), style = MaterialTheme.typography.labelSmall)
            track?.qualityBadge?.let { Text(it, style = MaterialTheme.typography.labelSmall) }
            Text(formatDuration(state.snapshot.durationMs), style = MaterialTheme.typography.labelSmall)
        }
        Spacer(Modifier.height(LekisTokens.Spacing.xl))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(LekisTokens.Spacing.xl)) {
            IconButton(onClick = vm::previous) { Icon(Icons.Filled.SkipPrevious, contentDescription = null, Modifier.size(36.dp)) }
            IconButton(onClick = vm::togglePlayPause, modifier = Modifier.size(72.dp)) {
                Icon(if (state.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, contentDescription = null, Modifier.size(56.dp))
            }
            IconButton(onClick = vm::next) { Icon(Icons.Filled.SkipNext, contentDescription = null, Modifier.size(36.dp)) }
        }
        // TODO：歌词页（上滑切换）、队列、音量、AirPlay/投放按钮
    }
}

/** 底部迷你播放条。没有正在播放的曲目时不显示。 */
@Composable
fun MiniPlayer(onExpand: () -> Unit, vm: NowPlayingViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
    val track = state.track ?: return
    Row(
        Modifier
            .fillMaxWidth()
            .height(LekisTokens.Size.miniPlayerHeight)
            .clickable(onClick = onExpand)
            .padding(horizontal = LekisTokens.Spacing.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Artwork(path = null, size = 44.dp, modifier = Modifier.clip(RoundedCornerShape(LekisTokens.Radius.artworkList)))
        Spacer(Modifier.width(LekisTokens.Spacing.md))
        Column(Modifier.weight(1f)) {
            Text(track.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                track.artists.joinToString(" / "),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
        IconButton(onClick = vm::togglePlayPause) {
            Icon(if (state.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, contentDescription = null)
        }
        IconButton(onClick = vm::next) { Icon(Icons.Filled.SkipNext, contentDescription = null) }
    }
}

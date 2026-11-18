package dev.lekis.designsystem.component

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import coil3.compose.AsyncImage
import dev.lekis.designsystem.LekisTokens
import dev.lekis.designsystem.LocalLekisColors

/** 封面图。`path` 是核心返回的本地缩略图路径；为空时显示占位图标。 */
@Composable
fun Artwork(path: String?, size: androidx.compose.ui.unit.Dp, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(LekisTokens.Radius.artworkList)
    Box(
        modifier = modifier
            .size(size)
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        if (path != null) {
            AsyncImage(model = path, contentDescription = null, contentScale = ContentScale.Crop)
        } else {
            Icon(Icons.Filled.MusicNote, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** 列表里的一行歌曲。大列表请配合 LazyColumn 的 `key` 使用。 */
@Composable
fun TrackListItem(
    title: String,
    subtitle: String,
    artworkPath: String?,
    qualityBadge: String?,
    loved: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = LekisTokens.Spacing.pageGutter, vertical = LekisTokens.Spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Artwork(artworkPath, LekisTokens.Size.listArtwork)
        Spacer(Modifier.width(LekisTokens.Spacing.md))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                subtitle,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (qualityBadge != null) {
            Text(
                qualityBadge,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = LekisTokens.Spacing.sm),
            )
        }
        if (loved) {
            Icon(
                Icons.Filled.Favorite,
                contentDescription = null,
                tint = LocalLekisColors.current.moon,
                modifier = Modifier.padding(start = LekisTokens.Spacing.sm).size(16.dpCompat),
            )
        }
    }
}

private val Int.dpCompat get() = androidx.compose.ui.unit.Dp(this.toFloat())

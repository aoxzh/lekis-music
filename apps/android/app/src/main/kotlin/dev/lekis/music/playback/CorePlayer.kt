package dev.lekis.music.playback

import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import dev.lekis.core.bridge.CoreBridge
import dev.lekis.core.bridge.PlaybackSnapshot
import dev.lekis.core.bridge.PlaybackState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach

/**
 * 把 Rust 播放引擎包装成 Media3 的 [Player]，交给 MediaSession。
 *
 * - 音频由 Rust 引擎直接输出（AAudio），这里不解码、不出声；
 * - 队列用 MediaItem 表示，`mediaId` 是核心的 track id；
 * - 状态来自 [CoreBridge.playback]，每次变化调用 [invalidateState]。
 *
 * TODO：
 * - 元数据（标题、艺人、封面）填进 MediaItem.mediaMetadata，锁屏和通知才有内容；
 * - 进度用外推的 PositionSupplier，避免每 250ms 刷新一次状态；
 * - 音频焦点、拔耳机暂停（ACTION_AUDIO_BECOMING_NOISY）。
 */
@OptIn(UnstableApi::class)
class CorePlayer(private val core: CoreBridge) : SimpleBasePlayer(Looper.getMainLooper()) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var snapshot = PlaybackSnapshot()
    private var queue: List<MediaItem> = emptyList()

    init {
        core.playback.onEach {
            snapshot = it
            invalidateState()
        }.launchIn(scope)
    }

    override fun getState(): State {
        val commands = Player.Commands.Builder()
            .addAll(
                Player.COMMAND_PLAY_PAUSE,
                Player.COMMAND_PREPARE,
                Player.COMMAND_STOP,
                Player.COMMAND_SEEK_TO_NEXT,
                Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_PREVIOUS,
                Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_MEDIA_ITEM,
                Player.COMMAND_SET_MEDIA_ITEM,
                Player.COMMAND_CHANGE_MEDIA_ITEMS,
                Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
                Player.COMMAND_GET_TIMELINE,
                Player.COMMAND_GET_METADATA,
                Player.COMMAND_RELEASE,
            )
            .build()

        val playlist = queue.mapIndexed { i, item ->
            MediaItemData.Builder(item.mediaId.ifEmpty { "item-$i" })
                .setMediaItem(item)
                .build()
        }

        val builder = State.Builder()
            .setAvailableCommands(commands)
            .setPlayWhenReady(snapshot.state == PlaybackState.Playing, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setPlaybackState(
                when (snapshot.state) {
                    PlaybackState.Idle -> Player.STATE_IDLE
                    PlaybackState.Loading, PlaybackState.Buffering -> Player.STATE_BUFFERING
                    PlaybackState.Playing, PlaybackState.Paused -> Player.STATE_READY
                    PlaybackState.Ended -> Player.STATE_ENDED
                },
            )
            .setPlaylist(playlist)

        val index = snapshot.queueIndex
        if (index != null && index in playlist.indices) {
            builder.setCurrentMediaItemIndex(index).setContentPositionMs(snapshot.positionMs)
        }
        return builder.build()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        if (playWhenReady) core.play() else core.pause()
        return Futures.immediateVoidFuture()
    }

    override fun handleSetMediaItems(
        mediaItems: MutableList<MediaItem>,
        startIndex: Int,
        startPositionMs: Long,
    ): ListenableFuture<*> {
        queue = mediaItems.toList()
        val ids = queue.mapNotNull { it.mediaId.toLongOrNull() }
        if (ids.isNotEmpty()) core.playTracks(ids, startIndex.coerceIn(0, ids.lastIndex))
        return Futures.immediateVoidFuture()
    }

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        when (seekCommand) {
            Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> core.next()
            Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> core.previous()
            Player.COMMAND_SEEK_TO_MEDIA_ITEM -> {
                val ids = queue.mapNotNull { it.mediaId.toLongOrNull() }
                if (mediaItemIndex in ids.indices) core.playTracks(ids, mediaItemIndex)
            }
            else -> core.seek(positionMs.coerceAtLeast(0))
        }
        return Futures.immediateVoidFuture()
    }

    override fun handlePrepare(): ListenableFuture<*> = Futures.immediateVoidFuture()

    override fun handleStop(): ListenableFuture<*> {
        core.pause()
        return Futures.immediateVoidFuture()
    }

    override fun handleRelease(): ListenableFuture<*> {
        scope.cancel()
        return Futures.immediateVoidFuture()
    }
}

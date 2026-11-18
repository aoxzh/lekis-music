package dev.lekis.music.playback

import android.content.ComponentName
import android.content.Context
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * UI 控制播放的唯一入口：通过 MediaController 连接 [LekisPlaybackService]。
 * ViewModel 注入它，而不是直接调用 CoreBridge 的播放方法。
 */
@Singleton
class PlaybackConnection @Inject constructor(@ApplicationContext private val context: Context) {

    private val controllerFuture = MediaController.Builder(
        context,
        SessionToken(context, ComponentName(context, LekisPlaybackService::class.java)),
    ).buildAsync()

    private fun withController(block: (MediaController) -> Unit) {
        controllerFuture.addListener({ block(controllerFuture.get()) }, ContextCompat.getMainExecutor(context))
    }

    /** 播放一组曲目，从 [start] 开始。 */
    fun playTracks(trackIds: List<Long>, start: Int) = withController { c ->
        c.setMediaItems(trackIds.map { MediaItem.Builder().setMediaId(it.toString()).build() }, start, 0L)
        c.prepare()
        c.play()
    }

    fun togglePlayPause() = withController { c -> if (c.playWhenReady) c.pause() else c.play() }

    fun next() = withController { it.seekToNext() }

    fun previous() = withController { it.seekToPrevious() }

    fun seekTo(positionMs: Long) = withController { it.seekTo(positionMs) }
}

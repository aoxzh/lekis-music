package dev.lekis.music.playback

import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import dagger.hilt.android.AndroidEntryPoint
import dev.lekis.core.bridge.CoreBridge
import javax.inject.Inject

/**
 * 播放服务。锁屏、通知、蓝牙按键、Android Auto 都通过这个 MediaSession 控制播放。
 *
 * TODO：
 * - Android Auto：改成 MediaLibraryService，实现浏览树（资料库 / 歌单 / 最近播放）；
 * - 通知样式和按钮（收藏、循环模式）。
 */
@AndroidEntryPoint
class LekisPlaybackService : MediaSessionService() {

    @Inject lateinit var core: CoreBridge

    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        session = MediaSession.Builder(this, CorePlayer(core)).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onDestroy() {
        session?.run {
            player.release()
            release()
        }
        session = null
        super.onDestroy()
    }
}

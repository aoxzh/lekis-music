package dev.lekis.lekis

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.view.KeyEvent
import android.view.View
import android.widget.RemoteViews
import com.ryanheise.audioservice.MediaButtonReceiver
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider
import java.io.File

/**
 * 桌面播放小组件。
 *
 * 数据由 Dart 端（lib/src/platform/android_home_widget.dart）经 home_widget 写进
 * SharedPreferences，这里只负责画；按钮复用 audio_service 通知栏用的同一条
 * 媒体按键通道（MediaButtonReceiver → AudioService → LekisAudioHandler），
 * 所以和通知栏、蓝牙按键的行为完全一致。
 *
 * 写数据的进程已经不在（pid 对不上）时，说明播放器没在运行：
 * 播放按钮改为打开 App 并开始播放，避免只拉起没有 Activity 的后台引擎。
 */
class LekisPlayerWidget : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val state = WidgetState.read(widgetData)
        val cover = loadCover(context, state.artPath)
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, buildViews(context, appWidgetManager, id, state, cover))
        }
    }

    // Android 12 以下没有按尺寸自动切布局，改大小时自己重画一次。
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return
        val state = WidgetState.read(HomeWidgetPlugin.getData(context))
        val cover = loadCover(context, state.artPath)
        appWidgetManager.updateAppWidget(
            appWidgetId,
            buildViews(context, appWidgetManager, appWidgetId, state, cover),
        )
    }

    private fun buildViews(
        context: Context,
        manager: AppWidgetManager,
        widgetId: Int,
        state: WidgetState,
        cover: Bitmap?,
    ): RemoteViews {
        val compact = fill(context, RemoteViews(context.packageName, R.layout.widget_player_compact), state, cover)
        val large = fill(context, RemoteViews(context.packageName, R.layout.widget_player_large), state, cover)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return RemoteViews(
                mapOf(
                    SizeF(160f, 40f) to compact,
                    SizeF(160f, LARGE_MIN_HEIGHT_DP.toFloat()) to large,
                ),
            )
        }
        val minHeight = manager.getAppWidgetOptions(widgetId)
            .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
        return if (minHeight >= LARGE_MIN_HEIGHT_DP) large else compact
    }

    private fun fill(context: Context, views: RemoteViews, state: WidgetState, cover: Bitmap?): RemoteViews {
        if (state.hasTrack) {
            views.setTextViewText(R.id.widget_title, state.title)
            views.setTextViewText(R.id.widget_artist, state.artist)
        } else {
            views.setTextViewText(R.id.widget_title, context.getString(R.string.widget_not_playing))
            views.setTextViewText(R.id.widget_artist, context.getString(R.string.widget_tap_to_open))
        }
        // 只有大布局有专辑行；对紧凑布局调用会被忽略（找不到 id 时 RemoteViews 不报错）。
        if (state.hasTrack && state.album.isNotEmpty()) {
            views.setTextViewText(R.id.widget_album, state.album)
            views.setViewVisibility(R.id.widget_album, View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.widget_album, View.GONE)
        }

        if (cover != null) {
            views.setImageViewBitmap(R.id.widget_cover, cover)
        } else {
            views.setImageViewResource(R.id.widget_cover, R.drawable.widget_cover_placeholder)
        }

        val playing = state.playing && state.writerAlive
        views.setImageViewResource(
            R.id.widget_play,
            if (playing) R.drawable.ic_media_pause else R.drawable.ic_media_play,
        )
        views.setContentDescription(
            R.id.widget_play,
            context.getString(if (playing) R.string.widget_pause else R.string.widget_play),
        )

        views.setOnClickPendingIntent(R.id.widget_root, launch(context, URI_OPEN))
        if (state.writerAlive) {
            views.setOnClickPendingIntent(R.id.widget_play, mediaButton(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
            views.setOnClickPendingIntent(R.id.widget_prev, mediaButton(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
            views.setOnClickPendingIntent(R.id.widget_next, mediaButton(context, KeyEvent.KEYCODE_MEDIA_NEXT))
        } else {
            // 播放器没在运行：三个按钮都打开 App，播放键额外请求恢复上次的会话并开始播放。
            views.setOnClickPendingIntent(R.id.widget_play, launch(context, URI_PLAY))
            views.setOnClickPendingIntent(R.id.widget_prev, launch(context, URI_OPEN))
            views.setOnClickPendingIntent(R.id.widget_next, launch(context, URI_OPEN))
        }
        return views
    }

    /** 和 audio_service 的 `AudioService.buildMediaButtonPendingIntent` 相同的写法。 */
    private fun mediaButton(context: Context, keyCode: Int): PendingIntent {
        val intent = Intent(context, MediaButtonReceiver::class.java)
            .setAction(Intent.ACTION_MEDIA_BUTTON)
            .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        return PendingIntent.getBroadcast(
            context,
            REQUEST_BASE + keyCode,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun launch(context: Context, uri: String): PendingIntent =
        HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse(uri))

    /** 解码并缩到 [COVER_PX] 以内再切圆角：RemoteViews 的位图走 Binder，不能太大。 */
    private fun loadCover(context: Context, path: String): Bitmap? {
        if (path.isEmpty()) return null
        val file = File(path)
        if (!file.isFile) return null
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= COVER_PX && bounds.outHeight / (sample * 2) >= COVER_PX) {
                sample *= 2
            }
            val decoded = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
                ?: return null
            val side = minOf(decoded.width, decoded.height)
            val square = Bitmap.createBitmap(
                decoded,
                (decoded.width - side) / 2,
                (decoded.height - side) / 2,
                side,
                side,
            )
            val scaled = if (side > COVER_PX) Bitmap.createScaledBitmap(square, COVER_PX, COVER_PX, true) else square
            // 与布局里 96dp 封面配 12dp 圆角的比例一致。
            rounded(scaled, scaled.width * 12f / 96f)
        } catch (e: Exception) {
            null
        } catch (e: OutOfMemoryError) {
            null
        }
    }

    private fun rounded(src: Bitmap, radius: Float): Bitmap {
        val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val rect = RectF(0f, 0f, src.width.toFloat(), src.height.toFloat())
        canvas.drawRoundRect(rect, radius, radius, paint)
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        canvas.drawBitmap(src, 0f, 0f, paint)
        return out
    }

    private data class WidgetState(
        val hasTrack: Boolean,
        val title: String,
        val artist: String,
        val album: String,
        val artPath: String,
        val playing: Boolean,
        /** 写这份数据的 App 进程还活着（和当前进程是同一个）。 */
        val writerAlive: Boolean,
    ) {
        companion object {
            fun read(prefs: SharedPreferences): WidgetState {
                // Dart 的 int 在通道里可能是 Int 也可能是 Long，按 Number 读。
                val pid = (prefs.all[KEY_PID] as? Number)?.toLong() ?: -1L
                return WidgetState(
                    hasTrack = prefs.getBoolean(KEY_HAS_TRACK, false),
                    title = prefs.getString(KEY_TITLE, null).orEmpty(),
                    artist = prefs.getString(KEY_ARTIST, null).orEmpty(),
                    album = prefs.getString(KEY_ALBUM, null).orEmpty(),
                    artPath = prefs.getString(KEY_ART, null).orEmpty(),
                    playing = prefs.getBoolean(KEY_PLAYING, false),
                    writerAlive = pid == android.os.Process.myPid().toLong(),
                )
            }
        }
    }

    private companion object {
        // 键名与 Dart 端 android_home_widget.dart 保持一致。
        const val KEY_HAS_TRACK = "lekis.widget.hasTrack"
        const val KEY_TITLE = "lekis.widget.title"
        const val KEY_ARTIST = "lekis.widget.artist"
        const val KEY_ALBUM = "lekis.widget.album"
        const val KEY_ART = "lekis.widget.art"
        const val KEY_PLAYING = "lekis.widget.playing"
        const val KEY_PID = "lekis.widget.pid"

        const val URI_OPEN = "lekis://widget/open"
        const val URI_PLAY = "lekis://widget/play"

        const val LARGE_MIN_HEIGHT_DP = 100
        const val COVER_PX = 288
        const val REQUEST_BASE = 0x4c00
    }
}

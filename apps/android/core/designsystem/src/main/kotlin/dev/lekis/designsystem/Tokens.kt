package dev.lekis.designsystem

import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.spring
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * 设计 Token。**必须和 design/tokens.json 保持一致**（以后由脚本生成，现在手动同步）。
 * 页面代码里不允许写死颜色、圆角、间距，一律引用这里。
 */
object LekisTokens {
    object Light {
        val background = Color(0xFFFBFAFF)
        val surface = Color(0xFFFFFFFF)
        val surfaceVariant = Color(0xFFF1EFF8)
        val surfaceElevated = Color(0xFFFFFFFF)
        val onBackground = Color(0xFF14131A)
        val onSurface = Color(0xFF14131A)
        val onSurfaceVariant = Color(0xFF5E5B6B)
        val outline = Color(0xFFDDDAE6)
        val accent = Color(0xFF5B57D6)
        val onAccent = Color(0xFFFFFFFF)
        val accentSoft = Color(0xFFE7E5FF)
        val moon = Color(0xFFE8B04B)
        val danger = Color(0xFFD6455B)
    }

    object Dark {
        val background = Color(0xFF0B0A10)
        val surface = Color(0xFF15141C)
        val surfaceVariant = Color(0xFF201E29)
        val surfaceElevated = Color(0xFF1C1B24)
        val onBackground = Color(0xFFF3F1FA)
        val onSurface = Color(0xFFF3F1FA)
        val onSurfaceVariant = Color(0xFFA9A5B8)
        val outline = Color(0xFF2E2C3A)
        val accent = Color(0xFF9C99FF)
        val onAccent = Color(0xFF0B0A10)
        val accentSoft = Color(0xFF2A2850)
        val moon = Color(0xFFF2C46B)
        val danger = Color(0xFFFF6B81)
    }

    object OledBlack {
        val background = Color(0xFF000000)
        val surface = Color(0xFF0A0A0D)
    }

    object Radius {
        val xs = 4.dp
        val sm = 8.dp
        val md = 12.dp
        val lg = 16.dp
        val xl = 24.dp
        val artworkList = 6.dp
        val artworkGrid = 10.dp
        val artworkNowPlaying = 14.dp
    }

    object Spacing {
        val xxs = 2.dp
        val xs = 4.dp
        val sm = 8.dp
        val md = 12.dp
        val lg = 16.dp
        val xl = 24.dp
        val xxl = 32.dp
        val xxxl = 48.dp
        val pageGutter = 16.dp
    }

    object Size {
        val listArtwork = 48.dp
        val gridArtworkMin = 160.dp
        val miniPlayerHeight = 64.dp
        val touchTargetMin = 48.dp
    }

    /** 弹簧参数，对应 tokens.json 的 motion.spring。 */
    object Motion {
        fun <T> standard(): SpringSpec<T> = spring(dampingRatio = 0.86f, stiffness = 380f)
        fun <T> emphasized(): SpringSpec<T> = spring(dampingRatio = 0.78f, stiffness = 220f)
        fun <T> gentle(): SpringSpec<T> = spring(dampingRatio = 1.0f, stiffness = 120f)
        fun <T> lyricsScroll(): SpringSpec<T> = spring(dampingRatio = 0.92f, stiffness = 90f)

        const val FAST_MS = 150
        const val NORMAL_MS = 250
        const val SLOW_MS = 400
        const val BACKGROUND_CROSSFADE_MS = 900
    }
}

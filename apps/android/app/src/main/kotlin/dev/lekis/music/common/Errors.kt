package dev.lekis.music.common

import androidx.annotation.StringRes
import dev.lekis.core.bridge.CoreBridgeException
import dev.lekis.music.R

/** 把核心错误映射成本地化提示。不要把 exception.message 直接显示给用户。 */
@StringRes
fun Throwable.userMessage(): Int = when ((this as? CoreBridgeException)?.kind) {
    CoreBridgeException.Kind.NotImplemented -> R.string.error_not_implemented
    CoreBridgeException.Kind.Network -> R.string.error_network
    else -> R.string.error_generic
}

/** 毫秒 → `m:ss`。 */
fun formatDuration(ms: Long): String {
    val totalSec = ms / 1000
    return "%d:%02d".format(totalSec / 60, totalSec % 60)
}

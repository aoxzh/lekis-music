package dev.lekis.lekis

import java.net.URI

/// A validated official video page. The native player only follows the exact
/// page it was opened with; subresources still load normally.
internal class VideoPage private constructor(val url: String, val title: String?) {
    fun allowsNavigation(target: String): Boolean =
        target.substringBefore('#') == url

    companion object {
        fun fromArguments(args: Any?): VideoPage? {
            if (args !is Map<*, *>) return null
            val raw = args["url"] as? String ?: return null
            val parsed = runCatching { URI(raw.trim()) }.getOrNull() ?: return null
            if (parsed.scheme != "https" || parsed.host.isNullOrBlank() || parsed.userInfo != null) {
                return null
            }
            val title = (args["title"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
            return VideoPage(parsed.toASCIIString(), title)
        }
    }
}

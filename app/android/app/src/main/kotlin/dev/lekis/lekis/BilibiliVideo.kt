package dev.lekis.lekis

internal class BilibiliVideo private constructor(val bvid: String, val page: Long) {
    private val query = "?bvid=$bvid&p=$page"
    val url = "https://player.bilibili.com/player.html$query"
    private val mobileUrl = "https://www.bilibili.com/blackboard/webplayer/mbplayer.html$query"

    fun allowsNavigation(target: String): Boolean {
        val document = target.substringBefore('#')
        return document == url || document == mobileUrl
    }

    companion object {
        private val bvidPattern = Regex("BV[0-9A-Za-z]{10}")

        fun fromArguments(args: Any?): BilibiliVideo? {
            if (args !is Map<*, *> || args.size != 2) return null
            return parse(args["bvid"], args["page"])
        }

        fun parse(bvid: Any?, page: Any?): BilibiliVideo? {
            if (bvid !is String || !bvidPattern.matches(bvid)) return null
            val number = when (page) {
                is Int -> page.toLong()
                is Long -> page
                else -> return null
            }
            if (number < 1) return null
            return BilibiliVideo(bvid, number)
        }
    }
}

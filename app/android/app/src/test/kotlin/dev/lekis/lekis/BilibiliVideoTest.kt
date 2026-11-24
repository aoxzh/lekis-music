package dev.lekis.lekis

import org.junit.Assert.*
import org.junit.Test

class BilibiliVideoTest {
    private val bvid = "BV1B7411m7LV"

    @Test fun validatesChannelTypesAndRange() {
        for (invalid in listOf(null, 5, " $bvid", "$bvid\n", "bv1B7411m7LV", "$bvid&p=3", "BV1中7411m7LV")) {
            assertNull(BilibiliVideo.parse(invalid, 1))
        }
        for (invalid in listOf(null, "1", 1.0, true, 0, -1L)) {
            assertNull(BilibiliVideo.parse(bvid, invalid))
        }
        assertEquals(2L, BilibiliVideo.parse(bvid, 2)?.page)
        assertEquals(Long.MAX_VALUE, BilibiliVideo.parse(bvid, Long.MAX_VALUE)?.page)
        assertNull(BilibiliVideo.fromArguments(mapOf("bvid" to bvid, "page" to 1, "url" to "https://example.org")))
        assertNull(BilibiliVideo.fromArguments(mapOf("bvid" to bvid)))
        assertNull(BilibiliVideo.fromArguments(listOf(bvid, 1)))
        assertEquals(bvid, BilibiliVideo.fromArguments(mapOf("bvid" to bvid, "page" to 1))?.bvid)
    }

    @Test fun allowsOnlyRequestedOfficialPlayer() {
        val video = BilibiliVideo.parse(bvid, 2)!!
        val expected = "https://player.bilibili.com/player.html?bvid=$bvid&p=2"
        assertEquals(expected, video.url)
        assertTrue(video.allowsNavigation(expected))
        assertTrue(video.allowsNavigation("$expected#player"))
        val mobile = "https://www.bilibili.com/blackboard/webplayer/mbplayer.html?bvid=$bvid&p=2"
        assertTrue(video.allowsNavigation(mobile))
        for (other in listOf(mobile.replace("p=2", "p=1"), mobile.replace(bvid, "BV17x411w7KC"),
                mobile.replace(".com/", ".com.example.org/"), mobile.replace("https:", "http:"),
                mobile.replace("mbplayer.html", "other.html"), "$mobile&p=1")) {
            assertFalse(other, video.allowsNavigation(other))
        }
        for (other in listOf("javascript:void(0)", "file:///tmp/test", "content://video",
                "intent://player", expected.replace("https:", "http:"),
                expected.replace(".com/", ".com.example.org/"),
                expected.replace(".com/", ".com@example.org/"),
                expected.replace("p=2", "p=3"), "$expected&next=elsewhere")) {
            assertFalse(other, video.allowsNavigation(other))
        }
    }
}

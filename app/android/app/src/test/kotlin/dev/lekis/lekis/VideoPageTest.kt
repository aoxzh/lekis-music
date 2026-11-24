package dev.lekis.lekis

import org.junit.Assert.*
import org.junit.Test

class VideoPageTest {
    private val url = "https://player.bilibili.com/player.html?bvid=BV1B7411m7LV&p=2"

    @Test fun validatesOnlyHttpsPages() {
        for (invalid in listOf(
            null,
            listOf(url),
            mapOf("href" to url),
            mapOf("url" to 5),
            mapOf("url" to ""),
            mapOf("url" to "http://player.bilibili.com/player.html"),
            mapOf("url" to "https:///nohost"),
            mapOf("url" to "https://user:pass@player.bilibili.com/x"),
            mapOf("url" to "javascript:void(0)"),
            mapOf("url" to "file:///tmp/video"),
            mapOf("url" to "content://video/1"),
            mapOf("url" to "$url with space"),
        )) {
            assertNull(VideoPage.fromArguments(invalid))
        }
    }

    @Test fun acceptsTitleAndAllowsOnlyTheRequestedPage() {
        val page = VideoPage.fromArguments(mapOf("url" to "  $url  ", "title" to "  MV  "))!!
        assertEquals(url, page.url)
        assertEquals("MV", page.title)
        assertTrue(page.allowsNavigation(url))
        assertTrue(page.allowsNavigation("$url#player"))
        assertNull(VideoPage.fromArguments(mapOf("url" to url, "title" to "   "))?.title)
        for (other in listOf(
            "javascript:void(0)",
            "file:///tmp/test",
            "content://video",
            "intent://player",
            url.replace("https:", "http:"),
            url.replace("player.bilibili.com", "player.bilibili.com.example.org"),
            url.replace("p=2", "p=3"),
            "$url&next=elsewhere",
        )) {
            assertFalse(other, page.allowsNavigation(other))
        }
    }
}

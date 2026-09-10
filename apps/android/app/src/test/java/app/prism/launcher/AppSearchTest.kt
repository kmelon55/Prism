package app.prism.launcher

import org.junit.Assert.*
import org.junit.Test

class AppSearchTest {
    private val kakao = SearchableApp("kakao", "카카오톡", "메신저")

    @Test fun `Korean initials and mixed syllables match`() {
        listOf("ㅋㅋㅇㅌ", "ㅋㅋ", "카ㅋㅇ", "카카오ㅌ", "카카오토", "ᄏᄏᄋᄐ", "카 카 오").forEach {
            assertNotNull("Expected $it to match KakaoTalk", AppSearch.score(kakao, it))
        }
    }

    @Test fun `IME decomposed Hangul matches composed app names`() {
        assertNotNull(AppSearch.score(kakao, "카카오"))
    }

    @Test fun `abbreviated initials match in order with a lower rank`() {
        assertNotNull(AppSearch.score(kakao, "ㅋㅌ"))
        assertTrue(AppSearch.score(kakao, "ㅋㅋㅇㅌ")!! < AppSearch.score(kakao, "ㅋㅌ")!!)
        assertNull(AppSearch.score(kakao, "ㅌㅋ"))
        assertNull(AppSearch.score(kakao, "ㅋㅋㅋㅋ"))
    }

    @Test fun `aliases match initials and exact names rank first`() {
        assertNotNull(AppSearch.score(kakao, "ㅁㅅㅈ"))
        assertEquals(0, AppSearch.score(kakao, "메신저"))
        assertTrue(AppSearch.score(kakao, "카카오톡")!! < AppSearch.score(kakao, "ㅋ")!!)
    }

    @Test fun `non matches stay excluded and longer queries are safe`() {
        listOf("ㅌㅋ", "ㄱㄱ", "카카오톡톡", "mail", "카가").forEach {
            assertNull("Unexpected match for $it", AppSearch.score(kakao, it))
        }
    }

    @Test fun `Latin case spaces and aliases are normalized`() {
        val app = SearchableApp("youtube", "YouTube Music", "유튜브 뮤직")
        assertNotNull(AppSearch.score(app, "YOUTUBE m"))
        assertNotNull(AppSearch.score(app, "ㅇㅌㅂㅁㅈ"))
        assertEquals(0, AppSearch.score(app, "   "))
    }

    @Test fun `sections prioritize Korean and fold double consonants`() {
        assertEquals("ㄱ", AppSearch.section("까까"))
        assertEquals("ㅅ", AppSearch.section("쏘카"))
        assertEquals("Y", AppSearch.section("YouTube"))
        assertEquals("#", AppSearch.section("123"))
        assertEquals("#", AppSearch.section(""))
    }
}

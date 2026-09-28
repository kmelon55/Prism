package app.prism.launcher

import org.junit.Assert.*
import org.junit.Test

class AppIndexTest {
    @Test fun englishModeUsesThePublishedEnglishNameInsteadOfKoreanPronunciation() {
        assertEquals("C", AppIndex.section("카메라", "Camera", false))
        assertEquals("G", AppIndex.section("갤러리", "Gallery", false))
        assertEquals("N", AppIndex.section("네이버", "NAVER", false))
    }

    @Test fun separateModeKeepsKoreanGroups() {
        assertEquals("ㅋ", AppIndex.section("카메라", "Camera", true))
        assertEquals("G", AppIndex.section("Gallery", "Gallery", true))
    }

    @Test fun missingEnglishResourcesKeepAppsReachableUnderNumberSign() {
        assertEquals("#", AppIndex.section("한글전용", "한글전용", false))
        assertEquals("#", AppIndex.section("123", "123", false))
        assertEquals("#", AppIndex.section("앱", "", false))
    }

    @Test fun englishRailIncludesAllEnglishSlotsAndNoKoreanSlots() {
        assertEquals(listOf("★") + ('A'..'Z').map(Char::toString) + "#",
            alphabetSections(listOf("Camera"), showKorean = false))
        assertEquals(listOf("★", "C", "#"),
            alphabetSections(listOf("Camera", "한글전용"), showAll = false, showKorean = false))
    }
}

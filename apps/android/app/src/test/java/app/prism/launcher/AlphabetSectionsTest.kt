package app.prism.launcher

import org.junit.Assert.*
import org.junit.Test

class AlphabetSectionsTest {
    @Test fun bilingualCatalogOmitsEmptyGroupsWithoutLosingEitherScript() {
        val sections = alphabetSections(listOf("카카오톡", "Settings", "9GAG", "갤러리"), showAll = false)
        assertEquals(listOf("★", "ㄱ", "ㅋ", "S", "#"), sections)
        assertEquals(sections.distinct(), sections)
    }

    @Test fun fullAlphabetIsTheDefaultEvenForMissingGroupsAndScripts() {
        assertEquals(listOf("★") + AppSearch.sectionOrder, alphabetSections(listOf("Calendar", "Settings")))
        assertEquals(listOf("★") + AppSearch.sectionOrder, alphabetSections(listOf("카카오톡", "Settings", "9GAG")))
    }

    @Test fun readableKoreanLabelsPreserveUnderlyingGroups() {
        assertEquals("가", alphabetLabel("ㄱ", true))
        assertEquals("하", alphabetLabel("ㅎ", true))
        assertEquals("ㄱ", alphabetLabel("ㄱ", false))
        assertEquals("A", alphabetLabel("A", true))
        assertEquals("★", alphabetLabel("★", true))
        assertEquals("#", alphabetLabel("#", true))
    }

    @Test fun emptyCatalogKeepsEverySlotWhileAppsLoad() {
        assertEquals(listOf("★") + AppSearch.sectionOrder, alphabetSections(emptyList()))
        assertEquals(listOf("★"), alphabetSections(emptyList(), showAll = false))
    }
}

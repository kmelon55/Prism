package app.prism.launcher

import org.junit.Assert.*
import org.junit.Test

class AlphabetSectionsTest {
    @Test fun bilingualCatalogKeepsBothAlphabetsInSearchOrder() {
        val sections = alphabetSections(listOf("카카오톡", "Settings", "9GAG", "갤러리"))
        assertEquals(listOf("★") + AppSearch.sectionOrder, sections)
        assertEquals(sections.distinct(), sections)
    }

    @Test fun sparseEnglishCatalogStillAllowsEveryLetter() {
        assertEquals(listOf("★") + ('A'..'Z').map(Char::toString), alphabetSections(listOf("Calendar", "Settings")))
    }

    @Test fun emptyCatalogStillHasAHomeTarget() {
        assertEquals(listOf("★"), alphabetSections(emptyList()))
    }
}

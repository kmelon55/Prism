package app.prism.launcher

import java.text.Normalizer
import java.util.Locale

data class SearchableApp(val id: String, val label: String, val alias: String = "")

/** Local, deterministic matching with Korean initials and composing-text support. */
object AppSearch {
    private const val INITIALS = "ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ"
    private const val GROUPS = "ㄱㄱㄴㄷㄷㄹㅁㅂㅂㅅㅅㅇㅈㅈㅊㅋㅌㅍㅎ"
    val sectionOrder = "ㄱㄴㄷㄹㅁㅂㅅㅇㅈㅊㅋㅌㅍㅎ".map(Char::toString) +
        ('A'..'Z').map(Char::toString) + "#"

    private fun key(text: String): String = Normalizer.normalize(text, Normalizer.Form.NFC)
        .lowercase(Locale.ROOT).filterNot(Char::isWhitespace).map { character ->
            if (character in '\u1100'..'\u1112') INITIALS[character - '\u1100'] else character
        }.joinToString("")

    private fun initial(character: Char): Char? =
        if (character in '가'..'힣') INITIALS[(character - '가') / 588] else null

    private fun characterMatches(actual: Char, typed: Char, last: Boolean): Boolean {
        if (actual == typed) return true
        if (typed in INITIALS && initial(actual) == typed) return true
        // While an IME is composing, e.g. 카카오ㅌ or 카카오토, keep 카카오톡 visible.
        if (last && actual in '가'..'힣' && typed in '가'..'힣') {
            val expanded = Normalizer.normalize(actual.toString(), Normalizer.Form.NFD)
            return expanded.startsWith(Normalizer.normalize(typed.toString(), Normalizer.Form.NFD))
        }
        return false
    }

    private fun matchIndex(text: String, query: String): Int {
        if (query.length > text.length) return -1
        return (0..text.length - query.length).firstOrNull { start ->
            query.indices.all { i -> characterMatches(text[start + i], query[i], i == query.lastIndex) }
        } ?: -1
    }

    private fun abbreviatedInitials(text: String, query: String): Boolean {
        if (query.length < 2 || query.any { it !in INITIALS }) return false
        var index = 0
        for (character in text) {
            if (initial(character) == query[index]) index++
            if (index == query.length) return true
        }
        return false
    }

    fun score(app: SearchableApp, query: String): Int? {
        val typed = key(query)
        if (typed.isEmpty()) return 0
        return listOf(app.label, app.alias).filter(String::isNotBlank).mapNotNull { candidate ->
            val normalized = key(candidate)
            when {
                normalized == typed -> 0
                normalized.startsWith(typed) -> 10
                else -> matchIndex(normalized, typed).takeIf { it >= 0 }?.let { 20 + it }
                    ?: if (abbreviatedInitials(normalized, typed)) 50 else null
            }
        }.minOrNull()
    }

    fun section(label: String): String {
        val first = key(label).firstOrNull() ?: return "#"
        if (first in '가'..'힣') return GROUPS[(first - '가') / 588].toString()
        if (first in 'a'..'z') return first.uppercaseChar().toString()
        return "#"
    }
}

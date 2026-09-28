package app.prism.launcher

/** Index classification is independent of the app's displayed name and search aliases. */
internal object AppIndex {
    fun order(showKorean: Boolean): List<String> =
        if (showKorean) AppSearch.sectionOrder else ('A'..'Z').map(Char::toString) + "#"

    fun section(label: String, englishLabel: String, showKorean: Boolean): String {
        val section = AppSearch.section(if (showKorean) label else englishLabel)
        return if (showKorean || section in order(false)) section else "#"
    }
}

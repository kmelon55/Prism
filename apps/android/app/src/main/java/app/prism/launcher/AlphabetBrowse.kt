package app.prism.launcher

internal data class BrowseStop(val position: Float, val offset: Float)

/** A stable thumb-height origin; leave a complete row visible on short/large-text screens. */
internal fun selectedBrowseAnchor(contentHeight: Float, viewportHeight: Float, rowHeight: Float): Float =
    (contentHeight * .35f).coerceIn(0f, (viewportHeight - rowHeight).coerceAtLeast(0f))

/** Select the actual lazy item so a large jump never measures every preceding app. */
internal fun browseItemAt(offsets: List<Float>, offset: Float): Int {
    val match = offsets.binarySearch(offset)
    return (if (match >= 0) match else -match - 2).coerceAtLeast(0)
}

/** Interpolate between installed groups, including gaps in the alphabet. */
internal fun interpolateBrowseOffset(stops: List<BrowseStop>, position: Float): Float {
    if (stops.isEmpty()) return 0f
    if (position <= stops.first().position) return stops.first().offset
    val upper = stops.indexOfFirst { it.position >= position }
    if (upper < 0) return stops.last().offset
    val before = stops[upper - 1]
    val after = stops[upper]
    val fraction = (position - before.position) / (after.position - before.position)
    return before.offset + (after.offset - before.offset) * fraction
}

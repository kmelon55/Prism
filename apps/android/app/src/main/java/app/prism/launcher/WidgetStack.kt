package app.prism.launcher

data class WidgetSlot(val id: Int, val height: Int)

/** Immutable stack transitions keep selection and per-widget sizing together. */
data class WidgetStack(val slots: List<WidgetSlot> = emptyList(), val selected: Int = -1) {
    val active: WidgetSlot? get() = slots.find { it.id == selected } ?: slots.firstOrNull()
    fun add(slot: WidgetSlot) = WidgetStack(slots.filterNot { it.id == slot.id } + slot, slot.id)
    fun select(id: Int) = if (slots.any { it.id == id }) copy(selected = id) else this
    fun step(direction: Int): WidgetStack {
        if (slots.isEmpty()) return this
        val index = slots.indexOf(active)
        return select(slots[Math.floorMod(index + direction, slots.size)].id)
    }
    fun remove(id: Int): WidgetStack {
        val next = slots.filterNot { it.id == id }
        val index = slots.indexOfFirst { it.id == id }.coerceAtLeast(0)
        val selection = if (active?.id == id) next.getOrNull(index.coerceAtMost(next.lastIndex))?.id ?: -1 else selected
        return WidgetStack(next, selection)
    }
    fun resize(height: Int) = copy(slots = slots.map { if (it.id == active?.id) it.copy(height = height) else it })
}

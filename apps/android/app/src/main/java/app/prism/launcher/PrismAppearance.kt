package app.prism.launcher

/** The legacy lighting switch remains readable; its enabled appearance is remembered separately. */
enum class PrismAppearance(val key: String) {
    Flat("flat"), Matte("matte"), Liquid("liquid");

    companion object {
        fun resolve(effects: Boolean, material: String, supportsLiquid: Boolean = true): PrismAppearance = when {
            !effects -> Flat
            material == Liquid.key && supportsLiquid -> Liquid
            else -> Matte
        }
    }
}

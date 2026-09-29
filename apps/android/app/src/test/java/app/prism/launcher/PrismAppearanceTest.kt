package app.prism.launcher

import org.junit.Assert.assertEquals
import org.junit.Test

class PrismAppearanceTest {
    @Test fun legacySwitchAndMissingMaterialPreserveTheExistingAppearance() {
        assertEquals(PrismAppearance.Matte, PrismAppearance.resolve(true, "matte"))
        assertEquals(PrismAppearance.Flat, PrismAppearance.resolve(false, "matte"))
        assertEquals(PrismAppearance.Flat, PrismAppearance.resolve(false, "liquid"))
        assertEquals(PrismAppearance.Matte, PrismAppearance.resolve(true, "unknown"))
    }

    @Test fun liquidHasAnExplicitOlderAndroidFallback() {
        assertEquals(PrismAppearance.Liquid, PrismAppearance.resolve(true, "liquid"))
        assertEquals(PrismAppearance.Matte, PrismAppearance.resolve(true, "liquid", supportsLiquid = false))
    }
}

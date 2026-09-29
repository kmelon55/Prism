package app.prism.launcher

import org.junit.Assert.*
import org.junit.Test

class AppCategoryTest {
    @Test fun declaredCategoryWinsOverLocalHints() {
        assertEquals(AppCategory.Games, inferAppCategory(0, "Music game", "com.example.music"))
        assertEquals(AppCategory.Productivity, inferAppCategory(7, "Camera", "com.example.camera"))
    }
    @Test fun missingMetadataUsesConservativeHintsAndSafeFallback() {
        assertEquals(AppCategory.Photos, inferAppCategory(-1, "Camera", "com.android.camera2"))
        assertEquals(AppCategory.Tools, inferAppCategory(-1, "Clock", "com.android.deskclock"))
        assertEquals(AppCategory.Other, inferAppCategory(-1, "Unknown", "com.example.unknown"))
        assertEquals(AppCategory.Other, inferAppCategory(-1, "Photosynthesis", "com.example.photosynthesis"))
        assertNull(AppCategory.fromKey("future-category"))
    }

    @Test fun specificCategoriesRefineBroadMetadataAndLocalizedNames() {
        assertEquals(AppCategory.Food, inferAppCategory(7, "Baemin", "com.sampleapp"))
        assertEquals(AppCategory.Food, inferAppCategory(-1, "Coupang Eats", "com.coupang.mobile.eats"))
        assertEquals(AppCategory.Shopping, inferAppCategory(-1, "Coupang", "com.example.shop"))
        assertEquals(AppCategory.Finance, inferAppCategory(7, "My app", "com.example.app", "우리은행"))
        assertEquals(AppCategory.Food, inferAppCategory(-1, "My app", "com.example.app", "요기요"))
        assertEquals(AppCategory.Travel, inferAppCategory(-1, "Naver Map", "com.example.app", "네이버 지도"))
        assertEquals(AppCategory.Trips, inferAppCategory(-1, "Agoda", "com.example.app"))
        assertEquals(AppCategory.Health, inferAppCategory(-1, "Fitness", "com.example.app"))
        assertEquals(AppCategory.Education, inferAppCategory(-1, "Duolingo", "com.example.app"))
        assertEquals(AppCategory.Reading, inferAppCategory(-1, "My app", "com.example.app", "밀리의 서재"))
        assertEquals(AppCategory.Browser, inferAppCategory(-1, "Chrome", "com.example.app"))
        assertEquals(AppCategory.Games, inferAppCategory(0, "Food Shopping Game", "com.example.app"))
    }

    @Test fun mediaMetadataSplitsIntoPhotoVideoAndAudioAndLegacyKeysStayValid() {
        assertEquals(AppCategory.Music, inferAppCategory(1, "Unknown", "com.example.app"))
        assertEquals(AppCategory.Video, inferAppCategory(2, "Unknown", "com.example.app"))
        assertEquals(AppCategory.Photos, inferAppCategory(3, "Unknown", "com.example.app"))
        assertEquals(AppCategory.Media, AppCategory.fromKey("media"))
        assertEquals(AppCategory.Travel, AppCategory.fromKey("travel"))
        assertNull(AppCategory.fromKey(RECENT_BROWSE_SECTION))
    }
}

package app.prism.launcher

internal enum class AppCategory(val key: String, val title: Int, val railTitle: Int = title) {
    Social("social", R.string.category_social, R.string.rail_social),
    Food("food", R.string.category_food, R.string.rail_food),
    Travel("travel", R.string.category_travel, R.string.rail_travel),
    Trips("trips", R.string.category_trips, R.string.rail_trips),
    Shopping("shopping", R.string.category_shopping),
    Finance("finance", R.string.category_finance, R.string.rail_finance),
    Productivity("productivity", R.string.category_productivity, R.string.rail_productivity),
    Tools("tools", R.string.category_tools, R.string.rail_tools),
    Browser("browser", R.string.category_browser, R.string.rail_browser),
    Photos("photos", R.string.category_photos, R.string.rail_photos),
    Video("video", R.string.category_video, R.string.rail_video),
    Music("music", R.string.category_music, R.string.rail_music),
    Health("health", R.string.category_health, R.string.rail_health),
    Education("education", R.string.category_education, R.string.rail_education),
    Reading("reading", R.string.category_reading, R.string.rail_reading),
    News("news", R.string.category_news),
    Games("games", R.string.category_games),
    // Retain the original key for existing manual overrides.
    Media("media", R.string.category_media, R.string.rail_media),
    Other("other", R.string.category_other);

    companion object {
        fun fromKey(key: String?) = entries.firstOrNull { it.key == key }
    }
}

private data class CategoryHint(val category: AppCategory, val words: Set<String>, val phrases: List<String>)
private val preciseCategoryHints = listOf(
    CategoryHint(AppCategory.Food, setOf("food", "restaurant", "restaurants", "recipe", "recipes", "doordash", "ubereats", "eats", "yogiyo", "baemin", "starbucks", "dining"),
        listOf("배달의민족", "배민", "요기요", "쿠팡이츠", "땡겨요", "배달", "맛집", "레시피", "스타벅스", "캐치테이블", "음식")),
    CategoryHint(AppCategory.Finance, setOf("bank", "banking", "finance", "wallet", "stocks", "investing", "paypal", "toss", "kakaobank", "kakaopay"),
        listOf("은행", "뱅크", "뱅킹", "증권", "카드", "가계부", "토스", "카카오페이", "네이버페이", "금융")),
    CategoryHint(AppCategory.Shopping, setOf("shopping", "shop", "coupang", "amazon", "ebay", "aliexpress", "temu", "musinsa", "karrot"),
        listOf("쿠팡", "쇼핑", "무신사", "당근", "번개장터", "11번가", "지마켓", "올리브영")),
    CategoryHint(AppCategory.Health, setOf("health", "fitness", "workout", "running", "strava", "fitbit", "meditation", "sleep", "hospital"),
        listOf("건강", "운동", "헬스", "만보기", "병원", "명상", "필라테스", "러닝")),
    CategoryHint(AppCategory.Education, setOf("education", "learning", "duolingo", "coursera", "classroom", "dictionary", "quizlet", "study"),
        listOf("학습", "교육", "공부", "영어", "사전", "듀오링고", "클래스룸", "인강")),
    CategoryHint(AppCategory.Reading, setOf("books", "ebook", "ebooks", "kindle", "reader", "webtoon", "comics", "ridi"),
        listOf("전자책", "독서", "웹툰", "리디", "밀리의서재", "교보문고", "카카오페이지", "소설")),
    CategoryHint(AppCategory.Trips, setOf("travel", "hotel", "hotels", "airbnb", "booking", "agoda", "tripadvisor", "flights", "airline", "expedia"),
        listOf("여행", "숙박", "호텔", "항공", "야놀자", "여기어때", "에어비앤비", "트리플")),
)
private val generalCategoryHints = listOf(
    CategoryHint(AppCategory.Social, setOf("phone", "dialer", "contacts", "messaging", "messages", "chat", "telegram", "whatsapp", "kakaotalk", "instagram", "discord", "facebook", "threads"), listOf("전화", "연락처", "메시지", "카카오톡", "인스타그램")),
    CategoryHint(AppCategory.Travel, setOf("maps", "map", "navigation", "transit", "subway", "bus", "taxi", "uber", "tmap"), listOf("지도", "내비", "네비", "지하철", "버스", "택시", "티맵", "카카오t", "코레일", "기차")),
    CategoryHint(AppCategory.Photos, setOf("camera", "gallery", "photos", "snapseed", "lightroom"), listOf("사진", "카메라", "갤러리")),
    CategoryHint(AppCategory.Music, setOf("music", "audio", "podcast", "podcasts", "spotify", "melon", "soundcloud"), listOf("음악", "뮤직", "멜론", "팟캐스트", "오디오")),
    CategoryHint(AppCategory.Video, setOf("video", "movies", "youtube", "netflix", "twitch", "tving", "wavve", "disney"), listOf("영상", "동영상", "유튜브", "넷플릭스", "티빙", "웨이브", "디즈니")),
    CategoryHint(AppCategory.Productivity, setOf("calendar", "email", "gmail", "notes", "tasks", "docs", "sheets", "drive", "notion", "slack", "outlook", "office", "todo", "zoom", "teams"), listOf("캘린더", "일정", "메모", "노트", "메일", "할일", "문서", "노션")),
    CategoryHint(AppCategory.Browser, setOf("browser", "chrome", "firefox", "edge", "brave", "internet", "search"), listOf("브라우저", "인터넷", "검색", "크롬", "네이버")),
    CategoryHint(AppCategory.News, setOf("news", "newspaper", "bbc", "cnn", "reuters"), listOf("뉴스", "신문")),
    CategoryHint(AppCategory.Tools, setOf("settings", "clock", "deskclock", "calculator", "files", "documentsui", "weather", "recorder", "authenticator", "vpn", "translate"), listOf("설정", "시계", "계산기", "파일", "날씨", "녹음", "인증", "번역")),
)

/** Entirely local: specific hints refine broad metadata; an explicit game declaration stays a game. */
internal fun inferAppCategory(platformCategory: Int, englishLabel: String, packageName: String, localizedLabel: String = englishLabel): AppCategory {
    if (platformCategory == 0) return AppCategory.Games
    // Package identity disambiguates labels/taglines that mention several services.
    when (packageName) {
        "com.sampleapp", "com.coupang.mobile.eats" -> return AppCategory.Food
    }
    val labels = java.text.Normalizer.normalize("$englishLabel $localizedLabel", java.text.Normalizer.Form.NFKC)
        .lowercase(java.util.Locale.ROOT)
    val words = (labels + " " + packageName.lowercase(java.util.Locale.ROOT)).split(Regex("[^a-z0-9]+")).toSet()
    val compact = labels.replace(Regex("\\s+"), "")
    fun matches(hint: CategoryHint) = hint.words.any { it in words } || hint.phrases.any { it in compact }
    preciseCategoryHints.firstOrNull(::matches)?.let { return it.category }
    when (platformCategory) {
        1 -> return AppCategory.Music
        2 -> return AppCategory.Video
        3 -> return AppCategory.Photos
        4 -> return AppCategory.Social
        5 -> return AppCategory.News
        6 -> return AppCategory.Travel
        7 -> return AppCategory.Productivity
        8 -> return AppCategory.Tools
    }
    return generalCategoryHints.firstOrNull(::matches)?.category ?: AppCategory.Other
}

internal fun appCategory(app: LauncherApp, overrides: Map<String, String>): AppCategory =
    AppCategory.fromKey(overrides[app.id]) ?: AppCategory.fromKey(app.category) ?: AppCategory.Other

internal const val RECENT_BROWSE_SECTION = "recent-apps"

internal fun categoryBrowseGroups(state: LauncherState): List<Pair<String, List<LauncherApp>>> {
    val byId = state.apps.associateBy { it.id }
    val recent = state.recent.distinct().mapNotNull(byId::get).take(12)
    val grouped = state.apps.groupBy { appCategory(it, state.categoryOverrides) }
    return buildList {
        if (recent.isNotEmpty()) add(RECENT_BROWSE_SECTION to recent)
        AppCategory.entries.forEach { category -> grouped[category]?.let { add("category:${category.key}" to it) } }
    }
}

internal fun browseSections(state: LauncherState): List<String> = if (state.browseByCategory) {
    listOf("★") + categoryBrowseGroups(state).map { it.first }
} else alphabetSections(state.apps.map { if (state.showKoreanIndex) it.label else it.englishLabel },
    state.showAllIndexLetters, state.showKoreanIndex)

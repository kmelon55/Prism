import Foundation

/// Common Korean and English names for popular apps. Exact app-name variants avoid assigning
/// browser aliases to unrelated helper apps.
public enum ApplicationAliases {
    private static let catalog: [(names: [String], aliases: [String])] = [
        (["Google Chrome", "Chrome"], ["크롬", "구글 크롬", "구글크롬", "chrome", "google 크롬"]),
        (["Safari", "사파리"], ["사파리", "safari"]),
        (["Firefox", "Mozilla Firefox"], ["파이어폭스", "firefox"]),
        (["Microsoft Edge", "Edge"], ["엣지", "마이크로소프트 엣지", "edge"]),
        (["Arc"], ["아크"]),
        (["Brave Browser", "Brave"], ["브레이브", "brave"]),
        (["Visual Studio Code"], ["비주얼 스튜디오 코드", "비주얼스튜디오코드", "브이에스코드", "vscode", "vs 코드", "code"]),
        (["Cursor"], ["커서"]),
        (["Terminal", "터미널"], ["터미널", "terminal"]),
        (["iTerm", "iTerm2"], ["아이텀", "아이텀2"]),
        (["Slack"], ["슬랙"]),
        (["Discord"], ["디스코드"]),
        (["Notion"], ["노션"]),
        (["Obsidian"], ["옵시디언"]),
        (["Figma"], ["피그마"]),
        (["Spotify"], ["스포티파이"]),
        (["KakaoTalk", "카카오톡"], ["카카오톡", "카톡", "kakaotalk"]),
        (["Telegram"], ["텔레그램"]),
        (["zoom.us", "Zoom", "Zoom Workplace"], ["줌", "zoom"]),
        (["Finder", "파인더"], ["파인더", "finder"]),
        (["System Settings", "System Preferences", "시스템 설정", "시스템 환경설정"], ["시스템 설정", "시스템설정", "환경설정", "system settings"]),
        (["Notes", "메모"], ["메모", "notes"]),
        (["Calendar", "캘린더"], ["캘린더", "달력", "calendar"]),
        (["Mail", "메일"], ["메일", "mail"]),
        (["Preview", "미리보기"], ["미리보기", "preview"]),
    ]

    private static let aliasesByName: [String: [String]] = {
        var map: [String: [String]] = [:]
        for entry in catalog {
            for name in entry.names { map[TextMatching.normalize(name)] = entry.aliases }
        }
        return map
    }()

    public static func common(for name: String) -> [String] {
        aliasesByName[TextMatching.normalize(name)] ?? []
    }
}

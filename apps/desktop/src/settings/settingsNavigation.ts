import { Mic, Archive, AppWindow, BoxSelect, Clipboard, Keyboard, Paintbrush, ShieldCheck, SlidersHorizontal, Sparkles, Terminal, type LucideIcon } from "lucide-react";
import { bilingual } from "../i18n";
import type { PreferencesSection } from "./SettingsView";

export interface SettingsSection {
  id: PreferencesSection;
  label: string;
  description: string;
  icon: LucideIcon;
  keywords: readonly string[];
}

export const preferenceSections: readonly SettingsSection[] = [
  { id: "general", label: "General", description: "Appearance and application behavior", icon: Paintbrush,
    keywords: ["Language", "App language", "Follow system", "Appearance", "Theme", "Dark", "Light", "Background opacity", "Background blur", "Behavior", "Application icons", "Reduce motion", "Animations", "애니메이션", "프리즘 반사광", "Opening light animation", "열릴 때 광원 애니메이션", "내부 반사광", "테두리 색감", "테두리 흰 반사광", "반사광 회전 주기", "Clear Icons"] },
  { id: "shortcut", label: "Launcher", description: "Open Prism from anywhere", icon: Keyboard,
    keywords: ["Global hotkey", "Open or hide Prism", "Shortcut", "Save", "Reset"] },
  { id: "ai", label: "AI", description: "API 키 연결과 기본 모델 선택", icon: Sparkles,
    keywords: ["API key", "API 키", "Model", "모델", "Gateway", "Provider", "제공자", "Chat", "채팅", "OpenAI", "Anthropic", "Google", "usage", "cost", "tokens", "사용량", "비용", "토큰", "그래프"] },
  { id: "dictation", label: "음성 받아쓰기", description: "Whisp 녹음, STT 모델과 자동 입력", icon: Mic, keywords: ["dictation", "Whisp", "voice", "speech", "STT", "받아쓰기", "녹음", "전사", "마이크", "파형", "whisper", "Groq", "xAI", "prompt", "refine", "프롬프트", "다듬기"] },
  { id: "applications", label: "Applications", description: "Aliases, hotkeys, and installed app visibility", icon: AppWindow,
    keywords: ["Installed applications", "Alias", "Hotkey", "Refresh", "Enable", "Disable"] },
  { id: "scripts", label: "Scripts", description: "Local script directories and command registry", icon: Terminal,
    keywords: ["Local directories", "Script command folders", "Add Directory", "Command registry", "Registry status", "Refresh Commands"] },
  { id: "window-management", label: "Window Management", description: "Layouts, aliases, and hotkeys", icon: BoxSelect,
    keywords: ["Move and resize", "Layout", "Alias", "Hotkey", "Accessibility"] },
  { id: "commands", label: "Commands", description: "Configure built-in commands", icon: SlidersHorizontal,
    keywords: ["Command", "Alias", "Hotkey", "Enable", "Disable"] },
  { id: "clipboard", label: "Clipboard", description: "Private, local clipboard history", icon: Clipboard,
    keywords: ["History", "Clipboard history", "Clear history", "Clear History", "Private by default", "Keep history for", "Retention", "보관", "Pinned", "고정", "Clear stored history"] },
  { id: "snippets", label: "Snippets", description: "단축어를 입력해 저장한 문구로 바꾸세요", icon: Keyboard,
    keywords: ["Snippet", "Expansion", "Keyword", "Abbreviation", "스니펫", "자동 확장", "단축어", "문구"] },
  { id: "backup", label: "Backup & Restore", description: "Export and review local backups", icon: Archive,
    keywords: ["Backup", "Restore", "Export", "Import", "Recovery", "Snippets", "Quicklinks", "Favorites", "Safe preferences", "백업", "복원", "가져오기", "내보내기"] },
  { id: "permissions", label: "Permissions", description: "System access used by native features", icon: ShieldCheck,
    keywords: ["Accessibility", "Window management", "Manage permission", "Request Access", "System Settings", "Check Again"] },
];

export const settingsNavigationGroups: readonly { label: string; sections: readonly PreferencesSection[] }[] = [
  { label: "Preferences", sections: ["general", "shortcut", "ai", "dictation"] },
  { label: "Tools", sections: ["applications", "scripts", "snippets", "window-management", "commands"] },
  { label: "Privacy", sections: ["clipboard", "backup", "permissions"] },
];

const normalize = (value: string) => value.normalize("NFKC").toLocaleLowerCase().trim();

/** Match every query token across both UI languages, regardless of the active locale. */
export function matchesSettingsSearch(section: SettingsSection, query: string, extraKeywords: readonly string[] = []): boolean {
  const tokens = normalize(query).split(/\s+/).filter(Boolean);
  const haystack = [section.label, section.description, ...section.keywords, ...extraKeywords]
    .flatMap((text) => bilingual(text)).map(normalize).join(" ");
  return tokens.every((token) => haystack.includes(token));
}

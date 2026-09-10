import { currentLocale } from "../i18n";

const messages = {
  title: ["Snippet expansion", "스니펫 자동 확장"],
  enable: ["Enable snippet expansion", "스니펫 자동 확장 켜기"],
  description: ["Off by default. Type a saved keyword such as ;email, then a space to expand it in a compatible text field.", "기본값은 꺼짐입니다. 지원하는 입력란에서 ;email 같은 저장된 약어를 입력하고 공백을 누르면 확장합니다."],
  desktop: ["Available in the macOS desktop app.", "macOS 데스크톱 앱에서 사용할 수 있습니다."],
  unavailable: ["Automatic expansion is unavailable in this build. Use Copy or Paste from Snippets.", "이 빌드에서는 자동 확장을 지원하지 않습니다. 스니펫에서 복사 또는 붙여넣기를 사용하세요."],
  active: ["Listening in compatible text fields", "지원하는 입력란에서 동작 중"],
  paused: ["Paused — review permissions or refresh status", "일시 중지됨 · 권한을 확인하거나 상태를 새로 고치세요"],
  off: ["Off", "꺼짐"],
  accessibility: ["Accessibility", "손쉬운 사용"],
  monitoring: ["Input Monitoring", "입력 모니터링"],
  granted: ["Allowed", "허용됨"],
  required: ["Needs access", "권한 필요"],
  permissions: ["Review permissions", "권한 확인"],
  refresh: ["Refresh status", "상태 새로 고침"],
  exclusions: ["Excluded applications", "제외할 앱"],
  exclusionsHint: ["Application bundle IDs, one per line. Password managers and Prism are always excluded.", "앱 번들 ID를 한 줄에 하나씩 입력하세요. 암호 관리자와 Prism은 항상 제외합니다."],
  saveExclusions: ["Save excluded applications", "제외할 앱 저장"],
  boundary: ["Uses ABC or U.S. input only. Korean and other input methods, secure fields, unsupported editors, and uncertain targets are skipped. Template snippets use the manual run flow.", "ABC 또는 미국 입력 소스에서만 동작합니다. 한글 등 입력기, 암호 입력란, 지원하지 않는 편집기, 대상을 확인할 수 없는 경우에는 건너뜁니다. 템플릿 스니펫은 직접 실행하세요."],
  privacy: ["No typing history is saved. Snippet text comes from your saved library.", "입력 기록을 저장하지 않습니다. 보관함에 저장된 스니펫 내용을 사용합니다."],
  keyword: ["Abbreviation (optional)", "약어 (선택)"],
  keywordHint: ["Start with ; ! / or :, then letters, numbers, _ - ; ! / :. Case sensitive, up to 48 characters. The keyword is saved; automatic expansion is unavailable in this build.", "; ! / : 중 하나로 시작하고 영문, 숫자, _ - ; ! / :를 입력하세요. 대소문자를 구분하며 최대 48자입니다. 약어는 저장되며 이 빌드에서는 자동 확장을 지원하지 않습니다."],
  invalidKeyword: ["Use 2–48 characters, starting with ; ! / or : and containing letters, numbers, _ - ; ! / :.", "; ! / :로 시작하는 2~48자 약어를 입력하세요. 영문, 숫자, _ - ; ! / :를 사용할 수 있습니다."],
  failed: ["Could not update snippet settings. Refresh status and try again.", "스니펫 설정을 변경하지 못했습니다. 상태를 새로 고친 뒤 다시 시도하세요."],
} as const;
export function snippetCopy(key: keyof typeof messages) { return messages[key][currentLocale() === "ko" ? 1 : 0]; }
export const validSnippetKeyword = (value: string | undefined) => !value || /^[;!/:][A-Za-z0-9_;!/:\-]{1,47}$/.test(value);

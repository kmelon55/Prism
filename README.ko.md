# Prism

[English](README.md) · [한국어](README.ko.md)

앱과 파일 검색, 클립보드, 명령 실행, AI 작업을 하나의 작은 화면에서 사용하는
macOS 키보드 런처입니다. MIT 라이선스로 공개된 무료 오픈소스 프로젝트입니다.

**[macOS용 Prism 다운로드](https://github.com/kmelon55/Prism/releases/latest)** ·
[기여 안내](CONTRIBUTING.md) · [릴리스 안내](docs/releases.md)

## 설치

**macOS 14 이상**에서 사용할 수 있습니다. Universal 빌드 하나로
**Apple Silicon과 Intel Mac**을 지원합니다.

1. [GitHub Releases](https://github.com/kmelon55/Prism/releases/latest)에서 `.dmg` 또는 `.zip`을 받습니다.
2. DMG를 열고 **Prism.app**을 **응용 프로그램**으로 옮깁니다. ZIP은 압축을 풀고 앱을 옮깁니다.
3. `/Applications/Prism.app`을 엽니다. 설치된 앱은 이 사본 하나만 사용하세요.
4. **⌘⇧Space**로 Prism을 표시하거나 숨기고, **⌘,**로 설정을 엽니다.

### 처음 실행할 때: 확인 없이 열기

현재 Prism은 **임시 서명(ad-hoc)만 적용되어 있으며 Apple 개발자 ID 서명과 공증은 없습니다.**
따라서 첫 실행 시 macOS가 개발자를 확인할 수 없다는 메시지로 실행을 막을 수 있습니다.
Prism 실행을 한 번 시도한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기**를
누르고 **열기**를 확인하세요. 이 저장소에서 직접 받은 신뢰할 수 있는 파일에만 적용하세요.
[Apple 공식 안내](https://support.apple.com/ko-kr/102445)를 참고할 수 있습니다.

창 배치와 다른 앱에 텍스트 입력은 손쉬운 사용 권한, 음성 입력은 마이크 권한이 필요합니다.
Apple 개발자 ID 서명이 없으므로 업데이트 후 macOS 권한을 다시 허용해야 할 수 있습니다.
업데이트 파일은 별도 서명으로 검증하며, 이는 Apple 공증과는 별개입니다.

## 평소 사용과 업데이트

팔레트를 숨겨도 Prism은 백그라운드에서 실행됩니다. 앱을 다시 열면 기존 실행 창이 나타납니다.
로그인할 때 실행하려면 **시스템 설정 → 일반 → 로그인 항목**에 **Prism.app**을 추가하세요.

설치된 앱은 시작 시와 이후 6시간마다 GitHub의 새 버전을 자동 확인합니다.
업데이트가 있으면 앱 알림과 **설정 → 일반**에서 확인하고 **다운로드 및 설치**를 누릅니다.
현재 작업을 마친 뒤 **Prism 재시작**으로 새 버전을 적용하세요.
확인은 자동이며, 설치와 재시작은 직접 선택합니다. **업데이트 확인** 버튼으로 즉시 확인할 수도 있습니다.
네트워크 오류가 생겨도 기존 앱은 계속 사용할 수 있습니다.

설정과 로컬 기록은 `~/Library/Application Support/dev.prism.desktop` 및 앱의 WebKit 저장소에,
제공자 API 키는 macOS 키체인에 보관합니다. 앱 업데이트는 이 데이터를 유지합니다.

## 주요 기능

- 앱·파일 검색, 별칭, 키보드 탐색, 전역 단축키
- 클립보드 기록, 스니펫, 스크립트 명령, 로컬 노트와 라이브러리 검색
- 창 배치, 계산기, 단위 변환, 기준일을 표시하는 환율 변환
- 사용자 API 키로 사용하는 AI 채팅과 음성 입력
- 한국어·영어 UI 및 한국어 검색 지원

현재 설치 파일은 macOS용입니다. Windows/Linux 데스크톱과 네이티브
[Android 런처](apps/android/README.md)는 개발 중이며 이번 릴리스에 설치 파일이 포함되지 않습니다.
일부 기능은 OS 권한, 로컬 모델 설치 또는 본인의 제공자 계정이 필요합니다.

## 개발

Node.js 22+, pnpm 10.27.0, Rust, Apple Command Line Tools가 필요합니다.

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test
pnpm build
cargo test --locked --manifest-path apps/desktop/src-tauri/Cargo.toml
```

브라우저 미리보기는 `pnpm --filter @prism/desktop dev`로,
네이티브 개발은 설치된 앱을 종료한 뒤 `pnpm tauri dev`로 직접 시작합니다.
기존 개발 서버가 실행 중이면 중복 실행하지 마세요. 개발 빌드에서는 업데이트를 설치하지 않습니다.
별도의 “Prism Test” 앱 사본을 만들지 않습니다.

일상적인 사용은 `/Applications/Prism.app`으로 통일합니다. 소스 수정은 GitHub 새 버전을
릴리스한 후 앱 업데이트로 받습니다. 설치된 앱에 개발 소스가 실시간 반영되지는 않습니다.
다음 버전 배포는 [릴리스 안내](docs/releases.md)를 참고하세요.

## 라이선스

[MIT](LICENSE). [Whisp 기반 음성 입력](apps/desktop/src-tauri/native/dictation/LICENSE-Whisp)을
포함한 외부 코드의 라이선스 고지는 해당 소스와 함께 보관합니다.
이 프로젝트는 Minecraft용 Prism Launcher와 관계가 없습니다.

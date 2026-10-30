# Prism

[English](README.md) · [한국어](README.ko.md)

앱과 파일 검색, 클립보드, 명령 실행, AI 작업을 하나의 작은 화면에서 사용하는 macOS 키보드 런처입니다.
Swift로 만든 네이티브 앱이며, MIT 라이선스로 공개된 무료 오픈소스 프로젝트입니다.

**[macOS용 Prism 다운로드](https://github.com/kmelon55/Prism/releases/latest)** ·
[기여 안내](CONTRIBUTING.md) · [릴리스 안내](docs/releases.md)

## 설치

**macOS 14 이상**에서 사용할 수 있습니다. Universal 빌드 하나로 **Apple Silicon과 Intel Mac**을 지원합니다.

1. [GitHub Releases](https://github.com/kmelon55/Prism/releases/latest)에서 `.dmg` 또는 `.zip`을 받습니다.
2. DMG를 열고 **Prism.app**을 **응용 프로그램**으로 옮깁니다. ZIP은 압축을 풀고 앱을 옮깁니다.
3. `/Applications/Prism.app`을 엽니다. 설치된 앱은 이 사본 하나만 사용하세요.
4. **⌘⇧Space**로 Prism을 표시하거나 숨기고(**설정 → 런처**에서 바꿀 수 있습니다), **⌘,**로 설정을 엽니다.

### 처음 실행할 때: 확인 없이 열기

Prism은 **고정된 로컬 인증서로 서명되었으며 Apple 공증은 받지 않았습니다.** 그래서 첫 실행 때 macOS가
개발자를 확인할 수 없다며 실행을 막을 수 있습니다. Prism 실행을 한 번 시도한 뒤 **시스템 설정 → 개인정보 보호 및
보안 → 확인 없이 열기**를 누르고 **열기**를 확인하세요. 이 저장소에서 직접 받은 신뢰할 수 있는 파일에만 적용하세요.
[Apple 공식 안내](https://support.apple.com/ko-kr/102445)를 참고할 수 있습니다.

기능에 필요할 때 권한을 요청합니다. 창 배치, 스니펫 자동 확장, 다른 앱에 텍스트 입력은 손쉬운 사용 권한,
음성 입력은 마이크 권한이 필요합니다. 업데이트도 같은 서명을 유지하므로 허용한 권한이 그대로 유지됩니다.

## 평소 사용과 업데이트

팔레트를 숨겨도 Prism은 백그라운드에서 실행됩니다. 로그인할 때 자동으로 시작하려면
**설정 → 일반 → 로그인 시 실행**을 켜세요.

설치된 앱은 시작할 때와 이후 6시간마다 GitHub에서 새 버전을 확인합니다. 새 버전은 **설정 → 일반**에 표시되며,
**다운로드 및 설치**를 누른 뒤 작업을 마치고 Prism을 다시 시작하면 적용됩니다. 모든 업데이트는 Prism 업데이트 키로
검증한 뒤에만 앱을 교체합니다.

설정과 로컬 기록은 `~/Library/Application Support/dev.prism.desktop`에, 제공자 API 키는 macOS 키체인에
보관합니다. 앱을 업데이트해도 둘 다 유지됩니다.

## 주요 기능

- 앱·파일 검색, 별칭, 즐겨찾기, 자주 쓴 항목 우선 정렬, 키보드 탐색, 전역 단축키
- 클립보드 기록, 자동 확장 스니펫, 빠른 링크, 노트, 스크립트 명령
- 창 배치, 단위·환율·날짜 계산기, 이모지 선택기, 시스템 명령
- 본인 API 키로 쓰는 AI 채팅과 음성 입력(로컬 모델 또는 제공자 모델)
- 백업과 Raycast 가져오기
- 한국어·영어 UI 및 한국어 검색

Prism 0.2부터는 네이티브 Swift 앱입니다. 0.1.x는 Tauri 앱이었으며, 소스는
[`legacy/tauri`](https://github.com/kmelon55/Prism/tree/legacy/tauri) 브랜치에 보관합니다. 설치된 0.1.x는 그 자리에서
네이티브 앱으로 업데이트됩니다. 별도의 네이티브 [Android 런처](apps/android/README.md)는 개발 중입니다.

## 개발

Xcode 27 또는 그 Command Line Tools(Swift 6.4, Xcode 26으로는 빌드되지 않음)가 필요하고, 릴리스 스크립트에는 Node.js 22+가 필요합니다.

```sh
cd apps/mac
swift build
swift test
scripts/build-app.sh      # 설치된 Prism과 따로 데이터를 쓰는 실행 가능한 "Prism Dev.app"
```

개발 빌드는 번들 ID `dev.prism.native-dev`와 별도 데이터 폴더를 사용하므로 설치된 앱에 영향을 주지 않습니다.
모듈 구조와 규칙은 [`apps/mac/README.md`](apps/mac/README.md), 패키징·서명·배포는 [릴리스 안내](docs/releases.md)를
참고하세요.

## 라이선스

[MIT](LICENSE). [Whisp 기반 음성 입력](apps/mac/Sources/PrismDictation/Resources/LICENSE-Whisp.txt),
[Unicode 이모지 데이터](apps/mac/Sources/PrismEmoji/Resources/UNICODE-LICENSE.txt)를 포함한 외부 코드의 라이선스 고지는
해당 소스와 함께 보관합니다. 이 프로젝트는 Minecraft용 Prism Launcher와 관계가 없습니다.

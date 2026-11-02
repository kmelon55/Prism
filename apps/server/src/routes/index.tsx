import { createFileRoute } from "@tanstack/react-router";
export const Route = createFileRoute("/")({ component: Home });
function Home() {
  return (
    <main
      style={{
        maxWidth: 620,
        margin: "12vh auto",
        padding: 32,
        fontFamily: "system-ui",
        lineHeight: 1.8,
        color: "#273142",
      }}
    >
      <small>PRISM · SELF-HOSTED</small>
      <h1>내 기기를 연결해요</h1>
      <p>
        Prism 설정의 동기화에서 이 서버 주소를 입력하세요. 연결한 기기끼리 공통
        설정과 암호화된 텍스트를 주고받을 수 있어요.
      </p>
      <h2>연결에 필요한 것</h2>
      <ol>
        <li>이 서버의 HTTPS 주소</li>
        <li>서버 관리자가 설정한 연결 코드</li>
        <li>
          첫 기기에서 만든 암호화 키 — 다른 기기에서도 같은 키를 사용하세요.
        </li>
      </ol>
      <p>
        기기별 설정과 연결 해제는 Prism 앱에서 관리해요. 서버는 설정과 클립보드
        본문을 복호화할 수 없어요.
      </p>
    </main>
  );
}

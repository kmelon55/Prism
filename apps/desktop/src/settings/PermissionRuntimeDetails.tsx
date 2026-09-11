import { AnimatedDetails } from "./InterfaceMotion";
import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { t } from "../i18n";
interface Runtime { executablePath: string; permissionTarget: string; bundled: boolean; adHoc: boolean; identifier?: string; codeHash?: string; pid: number }
export function PermissionRuntimeDetails({ nativeRuntime, granted }: { nativeRuntime: boolean; granted: boolean }) {
  const [runtime, setRuntime] = useState<Runtime>();
  const [error, setError] = useState("");
  useEffect(() => {
    if (!nativeRuntime) return;
    let active = true;
    void invoke<Runtime>("get_permission_runtime").then(value => { if (active) setRuntime(value); }).catch(error => { if (active) setError(String(error)); });
    return () => { active = false; };
  }, [nativeRuntime]);
  if (!runtime) return error ? <p className="preference-alert" role="alert">{error}</p> : null;
  return <div className="settings-group permission-group">
    <div className="settings-row"><div className="preference-copy"><strong>{t("현재 실행 중인 권한 대상")}</strong><span>{runtime.bundled ? t("이 앱에 허용된 권한을 확인합니다.") : t("개발 실행 파일입니다. 설치된 Prism.app의 권한과 다를 수 있습니다.")}</span></div></div>
    {!granted && <p className="dictation-notice">{t("시스템 설정에 Prism이 켜져 있어도 아래 경로와 다르면 현재 앱의 권한이 아닙니다. 이 대상을 추가해 허용하세요. 돌아오면 자동으로 다시 확인합니다.")}</p>}
    <div className="dictation-field"><code style={{ overflowWrap: "anywhere" }}>{runtime.permissionTarget}</code>
      <button className="settings-toolbar-button" onClick={() => void invoke("reveal_permission_target").catch(error => setError(String(error)))}>{t("현재 실행 파일 보기")}</button>
    </div>
    {runtime.adHoc && <p className="dictation-notice">{t("임시 서명 빌드라 네이티브 재빌드 후 권한을 다시 허용해야 할 수 있습니다. 화면 코드만 갱신하는 HMR과는 다릅니다.")}</p>}
    {runtime.adHoc && !granted && <p className="dictation-notice">{t("같은 경로가 이미 켜져 있어도 재빌드했다면 해당 항목을 제거하고 현재 실행 파일을 다시 추가해 허용하세요.")}</p>}
    <AnimatedDetails className="dictation-advanced"><summary>{t("실행 정보")}</summary><div className="dictation-field"><code>{runtime.identifier ?? "—"} · PID {runtime.pid}</code><code style={{ overflowWrap: "anywhere" }}>{runtime.codeHash ?? "—"}</code></div></AnimatedDetails>
    {error && <p role="alert">{error}</p>}
  </div>;
}

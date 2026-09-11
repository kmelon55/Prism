import { AnimatedCollapse } from "./InterfaceMotion";
import { SettingsSlider } from "./SettingsSlider";
import { t } from "../i18n";
import type { SettingsPreferences } from "./SettingsView";
import { normalizeReflections } from "./reflectionPreferences";
export function AnimationSettings({ preferences, onChange }: { preferences: SettingsPreferences; onChange(value: SettingsPreferences): void }) {
  const reflection = normalizeReflections(preferences);
  return <>
    <div className="settings-row"><div className="preference-copy"><strong>{t("Animations")}</strong></div><button className={`switch ${!preferences.reduceMotion ? "active" : ""}`} role="switch" aria-label={t("Animations")} aria-checked={!preferences.reduceMotion} onClick={() => onChange({ ...preferences, reduceMotion: !preferences.reduceMotion })}><span /></button></div>
    <AnimatedCollapse open={!preferences.reduceMotion} reducedMotion={preferences.reduceMotion}><div className="reflection-settings" role="group" aria-label={t("프리즘 반사광")}>
      <div className="settings-row"><div className="preference-copy"><strong>{t("Opening light animation")}</strong></div><button className={`switch ${reflection.openingLightAnimation ? "active" : ""}`} role="switch" aria-label={t("Opening light animation")} aria-checked={reflection.openingLightAnimation} onClick={() => onChange({ ...preferences, openingLightAnimation: !reflection.openingLightAnimation })}><span /></button></div>
      <div className="settings-row"><div className="preference-copy"><strong>{t("내부 반사광")}</strong></div><label className="range-control"><SettingsSlider min="0" max="100" aria-label={t("내부 반사광")} value={reflection.reflectionIntensity} onChange={event => onChange({ ...preferences, reflectionIntensity: Number(event.target.value) })} /><span className="range-value">{reflection.reflectionIntensity}%</span></label></div>
      <div className="settings-row"><div className="preference-copy"><strong>{t("테두리 색감")}</strong></div><label className="range-control"><SettingsSlider min="0" max="100" aria-label={t("테두리 색감")} value={reflection.reflectionEdge} onChange={event => onChange({ ...preferences, reflectionEdge: Number(event.target.value) })} /><span className="range-value">{reflection.reflectionEdge}%</span></label></div>

      <div className="settings-row"><div className="preference-copy"><strong>{t("테두리 흰 반사광")}</strong></div><label className="range-control"><SettingsSlider min="0" max="100" step="1" aria-label={t("테두리 흰 반사광")} value={reflection.reflectionHighlight} onInput={event => onChange({ ...preferences, reflectionHighlight: event.currentTarget.valueAsNumber })} /><span className="range-value">{reflection.reflectionHighlight}%</span></label></div>
      <p className="ai-settings-note">{t("macOS 동작 줄이기가 켜져 있으면 반사광은 정지된 상태로 표시됩니다.")}</p>
    </div></AnimatedCollapse>
  </>;
}

import { act } from "react";
import { createRoot } from "react-dom/client";
import { expect, it, vi } from "vitest";
import { AnimationSettings } from "./AnimationSettings";
import { normalizeReflections } from "./reflectionPreferences";
import type { SettingsPreferences } from "./SettingsView";
it("migrates legacy settings and bounds persisted reflection controls", () => {
  expect(normalizeReflections(null)).toEqual({openingLightAnimation:true,reflectionIntensity:65,reflectionEdge:20,reflectionHighlight:40,reflectionSpeed:40});
  expect(normalizeReflections({reflectionIntensity:NaN,reflectionEdge:999,reflectionHighlight:-1,reflectionSpeed:-1})).toEqual({openingLightAnimation:true,reflectionIntensity:65,reflectionEdge:100,reflectionHighlight:0,reflectionSpeed:20});
});
it("shows independent controls under Animations and preserves their values when disabled", async () => {
  Object.defineProperty(navigator,"language",{value:"en-US",configurable:true}); localStorage.clear();
  const element=document.createElement("div");document.body.append(element);const root=createRoot(element);const change=vi.fn();
  const preferences={reduceMotion:false,reflectionIntensity:72,reflectionEdge:18,reflectionSpeed:55} as SettingsPreferences;
  await act(async()=>root.render(<AnimationSettings preferences={preferences} onChange={change}/>));
  expect(element.querySelectorAll('input[type="range"]')).toHaveLength(3);
  await act(async()=>element.querySelector<HTMLButtonElement>('[role="switch"]')!.click());
  expect(change).toHaveBeenCalledWith({...preferences,reduceMotion:true});
  await act(async()=>root.render(<AnimationSettings preferences={{...preferences,reduceMotion:true}} onChange={change}/>));
  expect(element.querySelectorAll('input[type="range"]')).toHaveLength(0);
  await act(async()=>root.unmount());element.remove();
});

it("saves the opening sweep independently of continuous reflections", async () => {
  const element = document.createElement("div"); document.body.append(element);
  const root = createRoot(element); const change = vi.fn();
  const preferences = { reduceMotion: false, openingLightAnimation: true, reflectionIntensity: 72 } as SettingsPreferences;
  await act(async () => root.render(<AnimationSettings preferences={preferences} onChange={change} />));
  const toggle = element.querySelector<HTMLButtonElement>('[aria-label="Opening light animation"]')!;
  expect(toggle.getAttribute("aria-checked")).toBe("true");
  await act(async () => toggle.click());
  expect(change).toHaveBeenCalledWith({ ...preferences, openingLightAnimation: false });
  expect(normalizeReflections({ openingLightAnimation: false }).openingLightAnimation).toBe(false);
  await act(async () => root.unmount()); element.remove();
});

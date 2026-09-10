import { act, useState } from "react";
import { createRoot } from "react-dom/client";
import { expect, it, vi } from "vitest";
import { captureRecordingKey, recordingConflict, recordingDefaults, singleModifier } from "./recordingShortcuts";
import { DictationDeliverySettings } from "./DictationDeliverySettings";
import { defaultSettings } from "./api";
import { t } from "../i18n";
const key = (values: Partial<KeyboardEvent> = {}) => ({ code:"KeyV",ctrlKey:true,altKey:true,shiftKey:false,metaKey:false,isComposing:false,repeat:false,...values });
it("records physical key combinations independently of input language",()=>{
  expect(captureRecordingKey(key())).toEqual({mode:"custom",kind:"keyCombination",keyCode:9,modifiers:6144,label:"⌃⌥V"});
  expect(captureRecordingKey(key({code:"Enter",shiftKey:true}))).toMatchObject({keyCode:36,modifiers:6656,label:"⌃⌥⇧Return"});
  expect(captureRecordingKey(key({isComposing:true}))).toBeNull();
  expect(captureRecordingKey(key({repeat:true}))).toBeNull();
});
it("supports Whisp single modifiers and excludes disabled shortcuts from conflicts",()=>{
  const control=singleModifier("Control")!;
  expect(control.kind).toBe("singleControl");
  expect(recordingConflict({...recordingDefaults,recordingPasteShortcut:control,recordingPasteAndEnterShortcut:control})).toBe(true);
  expect(recordingConflict({...recordingDefaults,recordingPasteShortcut:control,recordingPasteAndEnterShortcut:{...control,mode:"disabled"}})).toBe(false);
});
it("keeps default copy separate from a user-recorded paste shortcut",async()=>{
  localStorage.clear();Object.defineProperty(navigator,"language",{configurable:true,value:"en-US"});
  const element=document.createElement("div");document.body.append(element);const root=createRoot(element);const changes=vi.fn();
  function Host(){const [settings,setSettings]=useState(defaultSettings);return <DictationDeliverySettings settings={settings} disabled={false} onChange={next=>{changes(next);setSettings(next);}}/>;}
  await act(async()=>root.render(<Host/>));
  async function select(label:string,value:string){const elementSelect=element.querySelector<HTMLSelectElement>(`select[aria-label="${label}"]`)!;await act(async()=>{Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,"value")!.set!.call(elementSelect,value);elementSelect.dispatchEvent(new Event("change",{bubbles:true}));});}
  await select(t("기본 결과 동작"),"copy");
  await select(t("{0} 단축키 방식",{0:t("붙여넣기")}),"custom");
  const recorder=element.querySelector<HTMLButtonElement>(`button[aria-label="${t("{0} 단축키 기록",{0:t("붙여넣기")})}"]`)!;
  await act(async()=>{recorder.click();});
  expect(document.activeElement).toBe(recorder);
  await act(async()=>{recorder.dispatchEvent(new KeyboardEvent("keydown",{key:"ㅍ",code:"KeyV",ctrlKey:true,altKey:true,bubbles:true,cancelable:true}));});
  expect(changes.mock.lastCall?.[0]).toMatchObject({defaultDelivery:"copy",recordingPasteShortcut:{mode:"custom",keyCode:9,modifiers:6144},recordingPasteAndEnterShortcut:{keyCode:36}});
  expect(recorder.textContent).toBe("⌃⌥V");
  // A modifier is recorded on release, and leaving the window discards a partial chord.
  await act(async()=>{recorder.click();});
  await act(async()=>{recorder.dispatchEvent(new KeyboardEvent("keydown",{key:"Control",code:"ControlLeft",ctrlKey:true,bubbles:true}));});
  await act(async()=>{window.dispatchEvent(new Event("blur"));});
  await act(async()=>{recorder.dispatchEvent(new KeyboardEvent("keyup",{key:"Control",bubbles:true}));});
  expect(recorder.textContent).toBe("⌃⌥V");
  await act(async()=>{recorder.click();});
  await act(async()=>{recorder.dispatchEvent(new KeyboardEvent("keydown",{key:"Control",code:"ControlLeft",ctrlKey:true,bubbles:true}));});
  await act(async()=>{recorder.dispatchEvent(new KeyboardEvent("keyup",{key:"Control",bubbles:true}));});
  expect(recorder.textContent).toBe("⌃");
  expect(changes.mock.lastCall?.[0].recordingPasteShortcut.kind).toBe("singleControl");
  await act(async()=>root.unmount());element.remove();
});

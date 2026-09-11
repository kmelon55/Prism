import { act } from "react";
import { createRoot } from "react-dom/client";
import { expect, it, vi } from "vitest";
import { SettingsSelect } from "./SettingsSelect";
it("uses a portal menu with keyboard selection, disabled-option skipping and focus restoration", async () => {
  const host=document.createElement("div");document.body.append(host);const root=createRoot(host);const change=vi.fn();
  await act(async()=>root.render(<SettingsSelect label="Language" value="en" options={[{value:"en",label:"English"},{value:"disabled",label:"Unavailable",disabled:true},{value:"ko",label:"한국어"}]} onChange={change}/>));
  const trigger=host.querySelector<HTMLButtonElement>('[role="combobox"]')!;
  const key=async(element:Element,key:string)=>{await act(async()=>{element.dispatchEvent(new KeyboardEvent("keydown",{key,bubbles:true,cancelable:true}));});};
  await key(trigger,"ArrowDown");
  const menu=document.querySelector('[role="listbox"]')!;
  expect(host.contains(menu)).toBe(false);expect(document.activeElement).toBe(menu);
  await key(menu,"ArrowDown");await key(menu,"Enter");
  expect(change).toHaveBeenLastCalledWith("ko");expect(document.activeElement).toBe(trigger);expect(document.querySelector('[role="listbox"]')).toBeNull();
  await act(async()=>trigger.click());await key(document.querySelector('[role="listbox"]')!,"Escape");
  expect(change).toHaveBeenCalledTimes(1);expect(document.activeElement).toBe(trigger);
  await act(async()=>root.unmount());host.remove();
});

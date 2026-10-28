import { StrictMode, act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { ModelPickerDialog } from "./ModelPickerDialog";
import { ModelPrice, ModelSpeed } from "./ModelMetrics";

let host: HTMLDivElement;
let root: Root;
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(async () => { await act(async () => root.unmount()); host.remove(); });

it("survives effect replay, contains wheel momentum, and restores focus on Escape", async () => {
  const parentKey = vi.fn();
  function Fixture() {
    const [open, setOpen] = useState(false);
    return <div onKeyDown={parentKey}><button onClick={() => setOpen(true)}>Open</button>{open && <ModelPickerDialog aria-label="Models" onDismiss={() => setOpen(false)}>
      <input type="search"/><div className="list" style={{overflowY: "auto"}}><button>Model</button></div>
    </ModelPickerDialog>}</div>;
  }
  await act(async () => root.render(<StrictMode><Fixture/></StrictMode>));
  const trigger = host.querySelector("button")!;
  await act(async () => { trigger.focus(); trigger.click(); });
  const list = host.querySelector<HTMLElement>(".list")!;
  Object.defineProperties(list, { scrollHeight: {value: 1000}, clientHeight: {value: 300} });
  expect(document.activeElement).toBe(host.querySelector("input"));
  expect(document.body.style.overflow).toBe("hidden");
  function wheel(deltaY: number) {
    const event = new WheelEvent("wheel", {deltaY, bubbles: true, cancelable: true});
    list.querySelector("button")!.dispatchEvent(event);
    return event.defaultPrevented;
  }
  list.scrollTop = 0;
  expect(wheel(-100)).toBe(true);
  expect(wheel(100)).toBe(false);
  list.scrollTop = 700;
  expect(wheel(100)).toBe(true);
  expect(wheel(-100)).toBe(false);
  await act(async () => host.querySelector("input")!.dispatchEvent(new KeyboardEvent("keydown", {key:"Escape",bubbles:true,cancelable:true})));
  expect(host.querySelector("dialog")).toBeNull();
  expect(parentKey).not.toHaveBeenCalled();
  expect(document.activeElement).toBe(trigger);
  expect(document.body.style.overflow).toBe("");
});

it("distinguishes free prices from unavailable prices and scopes speed references to their provider", async () => {
  await act(async () => root.render(<><ModelPrice price={0}/><ModelPrice price={null}/><ModelPrice price={NaN}/><ModelSpeed provider="vercel" model="google/gemini-2.5-flash-lite"/><ModelSpeed provider="openrouter" model="google/gemini-2.5-flash-lite"/></>));
  const cells = host.querySelectorAll(".model-metric");
  expect(cells[0].textContent).toBe("$0");
  expect(cells[0].querySelectorAll('[data-filled="true"]')).toHaveLength(0);
  expect(cells[1].textContent).toBe("—");
  expect(cells[1].querySelector(".model-meter")).toBeNull();
  expect(cells[2].textContent).toBe("—");
  expect(cells[3].textContent).toBe("477 t/s");
  expect(cells[3].getAttribute("title")).toContain("2026-10-28");
  expect(cells[4].textContent).toBe("—");
});

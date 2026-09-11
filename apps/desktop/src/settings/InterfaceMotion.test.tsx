import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { AnimatedDetails, InterfaceMotion } from "./InterfaceMotion";

let host: HTMLDivElement, root: Root;
let animations: { cancel: ReturnType<typeof vi.fn>; onfinish: (() => void) | null }[];
beforeEach(() => {
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  animations = [];
  vi.spyOn(Element.prototype, "getBoundingClientRect").mockImplementation(function (this: Element) {
    return { height: this.tagName === "SUMMARY" ? 24 : (this as HTMLDetailsElement).open ? 124 : 24 } as DOMRect;
  });
  Object.defineProperty(Element.prototype, "animate", { configurable: true, value: vi.fn(() => {
    const animation = { cancel: vi.fn(), onfinish: null as (() => void) | null }; animations.push(animation); return animation;
  }) });
});
afterEach(async () => { await act(async () => root.unmount()); host.remove(); vi.restoreAllMocks(); delete (Element.prototype as unknown as { animate?: unknown }).animate; });
const mount = async (quiet = false) => act(async () => root.render(<InterfaceMotion reducedMotion={quiet}>
  <AnimatedDetails><summary>Options</summary><input aria-label="Nested option" /></AnimatedDetails>
</InterfaceMotion>));
const toggle = async () => act(async () => host.querySelector("summary")!.click());
const finish = async () => act(async () => animations.at(-1)?.onfinish?.());

it("animates opening and closing while making closing content non-interactive", async () => {
  await mount(); await toggle();
  expect(host.querySelector("details")!.open).toBe(true);
  expect(Element.prototype.animate).toHaveBeenLastCalledWith([{ height: "24px" }, { height: "124px" }], expect.objectContaining({ duration: 240 }));
  await finish(); await toggle();
  expect(host.querySelector("details")!.open).toBe(true);
  expect(host.querySelector(".animated-details-content")!.hasAttribute("inert")).toBe(true);
  expect(Element.prototype.animate).toHaveBeenLastCalledWith([{ height: "124px" }, { height: "24px" }], expect.anything());
  await finish();
  expect(host.querySelector("details")!.open).toBe(false);
  expect(host.querySelector("details")!.style.overflow).toBe("");
});
it("reverses a pending close and ignores the cancelled completion", async () => {
  await mount(); await toggle(); await finish(); await toggle();
  const closing = animations.at(-1)!;
  await toggle();
  expect(closing.cancel).toHaveBeenCalled();
  await act(async () => closing.onfinish?.());
  expect(host.querySelector("details")!.open).toBe(true);
  await finish();
  expect(host.querySelector("details")!.open).toBe(true);
  expect(host.querySelector(".animated-details-content")!.hasAttribute("inert")).toBe(false);
});
it("uses immediate native disclosure behavior when motion is reduced", async () => {
  await mount(true); await toggle();
  expect(animations).toHaveLength(0);
  expect(host.querySelector("details")!.open).toBe(true);
  await toggle(); expect(host.querySelector("details")!.open).toBe(false);
});

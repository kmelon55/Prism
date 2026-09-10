import { vi } from "vitest";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
Object.defineProperty(window, "matchMedia", {
  writable: true,
  value: vi.fn(() => ({ matches: false, addEventListener() {}, removeEventListener() {} })),
});
HTMLElement.prototype.scrollTo = function (options: ScrollToOptions | number = {}, y?: number) {
  this.scrollTop = typeof options === "number" ? y ?? 0 : options.top ?? 0;
};

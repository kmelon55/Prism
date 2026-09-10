import { expect, it } from "vitest";
import { ShortcutCapture, doubleShortcutKeys } from "./shortcutCapture";
const control = (timeStamp: number, down = true) => ({ key: "Control", code: "ControlLeft", ctrlKey: down, altKey: false, metaKey: false, shiftKey: false, repeat: false, isComposing: false, timeStamp });
it("captures Control twice on the second press with Whisp's release-to-press interval", () => {
  const capture = new ShortcutCapture();
  expect(capture.keydown(control(0))).toBeUndefined();
  capture.keyup(control(500, false));
  expect(capture.keydown(control(920))).toBe("DoubleControl");
  expect(doubleShortcutKeys("DoubleControl")).toEqual(["⌃", "⌃"]);
  expect(doubleShortcutKeys("Super+Space")).toBeUndefined();
});
it("does not treat a held key, timeout, unrelated key or another modifier as a double tap", () => {
  for (const interrupt of ["timeout", "key", "modifier", "reset"]) {
    const capture = new ShortcutCapture();
    capture.keydown(control(0));
    expect(capture.keydown(control(10))).toBeUndefined();
    capture.keyup(control(20, false));
    if (interrupt === "key") capture.keydown({ ...control(30), key: "ㅁ", code: "KeyA" });
    if (interrupt === "modifier") capture.keydown({ ...control(30), key: "Shift", shiftKey: true });
    if (interrupt === "reset") capture.reset();
    expect(capture.keydown(control(interrupt === "timeout" ? 441 : 40))).toBeUndefined();
  }
});
it("records normal combinations and all four double modifiers using the same recorder", () => {
  const capture = new ShortcutCapture();
  expect(capture.keydown({ ...control(0), key: "ㅁ", code: "KeyA" })).toBe("Control+KeyA");
  for (const [key, modifier, name] of [["Control", "ctrlKey", "DoubleControl"], ["Alt", "altKey", "DoubleOption"], ["Shift", "shiftKey", "DoubleShift"], ["Meta", "metaKey", "DoubleCommand"]]) {
    capture.reset();
    const event = { ...control(0, false), key, [modifier]: true };
    capture.keydown(event); capture.keyup({ ...event, [modifier]: false, timeStamp: 10 });
    expect(capture.keydown({ ...event, timeStamp: 100 })).toBe(name);
  }
});

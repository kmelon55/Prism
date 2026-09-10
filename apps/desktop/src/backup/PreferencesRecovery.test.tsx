import { act } from "react";
import { createRoot } from "react-dom/client";
import { expect, it, vi } from "vitest";
import { PreferencesRecovery } from "./PreferencesRecovery";
import type { PreferencesRecoveryReview } from "./preferencesPersistence";
it("requires explicit recovery, blocks duplicate actions, and requires review again after failure", async () => {
  localStorage.setItem("prism:preferences", '{"language":"en"}');
  const container = document.createElement("div"); document.body.append(container); const root = createRoot(container);
  const review: PreferencesRecoveryReview = { preferences: { language: "en", theme: "dark", reduceMotion: false, backgroundOpacity: 97, backgroundBlur: 44, showApplicationIcons: true, commandAliases: { "prism:settings": "settings" } }, original: "{", snapshot: "fixture", created: Date.now() };
  let reject!: (error: Error) => void;
  const recover = vi.fn(() => new Promise<void>((_resolve, fail) => { reject = fail; }));
  const reviewAgain = vi.fn();
  try {
    await act(async () => root.render(<PreferencesRecovery review={review} onRecover={recover} onReviewAgain={reviewAgain}/>));
    expect(recover).not.toHaveBeenCalled();
    expect(container.textContent).toContain("prism:settings");
    const [recoverButton, retryButton] = [...container.querySelectorAll("button")];
    await act(async () => { recoverButton.click(); recoverButton.click(); }); expect(recover).toHaveBeenCalledTimes(1);
    await act(async () => reject(new Error("storage unavailable")));
    expect(container.querySelector('[role="alert"]')?.textContent).toBe("storage unavailable"); expect(recoverButton.disabled).toBe(true);
    await act(async () => retryButton.click()); expect(reviewAgain).toHaveBeenCalledTimes(1); expect(recover).toHaveBeenCalledTimes(1);
  } finally { await act(async () => root.unmount()); container.remove(); }
});
it("shows an unavailable snapshot without offering an automatic reset", async () => {
  localStorage.setItem("prism:preferences", '{"language":"en"}');
  const container = document.createElement("div"); const root = createRoot(container); const recover = vi.fn();
  try {
    await act(async () => root.render(<PreferencesRecovery review={null} onRecover={recover} onReviewAgain={() => {}}/>));
    expect(container.textContent).toContain("No valid settings snapshot"); expect(container.querySelectorAll("button")).toHaveLength(1); expect(recover).not.toHaveBeenCalled();
  } finally { await act(async () => root.unmount()); }
});

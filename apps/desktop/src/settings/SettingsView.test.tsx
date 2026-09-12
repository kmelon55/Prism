import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SettingsView, type SettingsViewProps } from "./SettingsView";

vi.mock("../AiSettings", () => ({ AiSettings: () => <div>AI configuration</div> }));
let container: HTMLDivElement;
let root: Root;
let props: SettingsViewProps;

beforeEach(() => {
  localStorage.clear();
  Object.defineProperty(navigator, "language", { configurable: true, value: "en-US" });
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  props = {
    preferences: { language: "en", theme: "system", reduceMotion: false, backgroundOpacity: 96,
      backgroundBlur: 20, showApplicationIcons: true, disabledCommandIds: [], commandAliases: {}, scriptDirectories: [] },
    onChange: vi.fn(), onClose: vi.fn(), onQuit: vi.fn(), nativeRuntime: false, commandKey: true,
    shortcut: { accelerator: "Super+Space", defaultAccelerator: "Super+Space", registered: true, isDefault: true, issue: null },
    shortcutDraft: "", shortcutError: "", shortcutBusy: false, shortcutRecording: false,
    onShortcutRecordingChange: vi.fn(), onShortcutRecord: vi.fn(), onShortcutReset: vi.fn(),
    onToggleCommand: vi.fn(), onRefreshApplications: vi.fn(), onClearIconCache: vi.fn(),
    clipboardEnabled: false, clipboardBusy: false, clipboardError: "", onClipboardToggle: vi.fn(), onClipboardClear: vi.fn(),
    commandShortcuts: {}, commandHotkeyError: "", accessibilityPermission: { supported: false, granted: false, canRequest: false, message: "Desktop only" },
    accessibilityPermissionBusy: false, accessibilityPermissionError: "", onAccessibilityPermissionRequest: vi.fn(),
    onAccessibilityPermissionRefresh: vi.fn(), onAccessibilitySettingsOpen: vi.fn(), onCommandAliasChange: vi.fn(),
    onCommandHotkeyRecordingChange: vi.fn(), onCommandHotkeyRecord: vi.fn(), onCommandHotkeyRemove: vi.fn(),
    standalone: true, systemCommands: [], applicationCatalogRevision: 0, iconCacheRevision: 0,
    scriptRegistryBusy: false, scriptRegistryStatus: "", scriptRegistryError: "", onScriptRegistryRefresh: vi.fn(),
    CommandGlyph: () => <span />,
  };
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); });
async function mount() { await act(async () => root.render(<SettingsView {...props} />)); }
function searchInput() { return container.querySelector<HTMLInputElement>('[type="search"]')!; }
async function search(value: string) {
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(searchInput(), value);
    searchInput().dispatchEvent(new Event("input", { bubbles: true }));
  });
}
function navigation() { return [...container.querySelectorAll("nav button")].map((button) => button.textContent); }
async function clickSection(label: string) {
  const button = [...container.querySelectorAll<HTMLButtonElement>("nav button")].find((button) => button.textContent === label)!;
  await act(async () => button.click());
}

describe("Settings discovery", () => {
  it("opens the exact matched control from keyboard search without changing its value", async () => {
    await mount(); await search("background blur");
    expect(container.querySelector('.settings-direct-results')?.textContent).toContain("Background blur");
    await act(async () => searchInput().dispatchEvent(new KeyboardEvent("keydown", {key:"Enter", bubbles:true, cancelable:true})));
    expect(searchInput().value).toBe("");
    expect(document.activeElement?.getAttribute("aria-label")).toBe("Background blur");
    expect(document.activeElement?.getAttribute("data-search-target")).toBe("true");
    expect(props.onChange).not.toHaveBeenCalled();
  });

  it("opens a matching window command and focuses its alias without executing it", async () => {
    await mount(); await search("left half");
    const result = [...container.querySelectorAll<HTMLButtonElement>('.settings-direct-results button')].find(button => button.textContent?.startsWith("Left Half"))!;
    await act(async () => result.click());
    expect(document.activeElement?.getAttribute("aria-label")).toBe("Alias for Left Half");
    expect(props.onCommandHotkeyRecord).not.toHaveBeenCalled();
  });
  it("finds explicit quit in Korean and keeps it unavailable in browser previews", async () => {
    await mount();
    await search("종료");
    expect(navigation()).toContain("General");
    const quit = [...container.querySelectorAll<HTMLButtonElement>("button")].find(button => button.textContent === "Quit Prism")!;
    expect(quit.disabled).toBe(true);
    props.nativeRuntime = true;
    await mount();
    await act(async () => quit.click());
    expect(props.onQuit).toHaveBeenCalledOnce();
    expect(props.onClose).not.toHaveBeenCalled();
  });

  it("discovers backup recovery in Korean and mounts only the backup section slot", async () => {
    props.backupDetails = <div data-backup-details>Review local backup</div>;
    await mount();
    await search("백업");
    expect(navigation()).toEqual(["Backup & Restore"]);
    expect(container.querySelector("[data-backup-details]")).not.toBeNull();
    await search("");
    await clickSection("General");
    expect(container.querySelector("[data-backup-details]")).toBeNull();
  });

  it("filters by control labels in either language and restores the selected section", async () => {
    await mount();
    await clickSection("Permissions");
    await search("배경 흐림");
    expect(navigation()).toEqual(["General"]);
    expect(container.querySelector('[aria-label="Background blur"]')).not.toBeNull();
    await search("");
    expect(container.querySelector('[aria-current="page"]')?.textContent).toBe("Permissions");
    await search("background opacity");
    expect(navigation()).toEqual(["General"]);
    await search("왼쪽 절반");
    expect(navigation()).toEqual(["Window Management"]);
  });

  it("shows no stale panel for empty results and clears search before closing on Escape", async () => {
    await mount();
    await search("no-such-settings-control");
    expect(navigation()).toEqual([]);
    expect(container.querySelector(".settings-scroll")?.textContent).toBe("");
    expect(container.querySelector('[role="status"]')?.textContent).toContain("No settings found");
    await act(async () => searchInput().dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true })));
    expect(searchInput().value).toBe("");
    expect(props.onClose).not.toHaveBeenCalled();
  });

  it("keeps composition Escape from clearing search or closing the window", async () => {
    await mount();
    await search("배경");
    await act(async () => searchInput().dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", isComposing: true, bubbles: true })));
    expect(searchInput().value).toBe("배경");
    expect(props.onClose).not.toHaveBeenCalled();
  });

  it("renders named navigation groups and the clipboard extension inside its section", async () => {
    props.clipboardDetails = <div data-clipboard-details>Retention controls</div>;
    await mount();
    expect(container.querySelectorAll("nav [role=group]")).toHaveLength(3);
    expect(navigation()).not.toContain("Applications");
    expect(navigation()).not.toContain("Scripts");
    await clickSection("Clipboard");
    expect(container.querySelector("[data-clipboard-details]")).not.toBeNull();
    expect(container.querySelector('[role="group"][aria-label="History"]')).toBeNull();
    await clickSection("General");
    expect(container.querySelector("[data-clipboard-details]")).toBeNull();
  });

  it("prefers an exact bilingual section label while allowing related sections to be selected", async () => {
    await mount();
    await clickSection("Commands");
    await search("클립보드");
    expect(container.querySelector('[aria-current="page"]')?.textContent).toBe("Clipboard");
    await clickSection("Commands");
    expect(container.querySelector('[aria-current="page"]')?.textContent).toBe("Commands");
    await search("");
    expect(container.querySelector('[aria-current="page"]')?.textContent).toBe("Commands");
  });

  it("honors native AI navigation even while a search filter hides the section", async () => {
    await mount();
    await search("background");
    props = {...props, requestedNavigation: {section: "ai"}};
    await mount();
    expect(searchInput().value).toBe("");
    expect(container.querySelector('[aria-current="page"]')?.textContent).toBe("AI");
    expect(container.querySelector(".settings-scroll")?.textContent).toBe("AI configuration");
  });
  it("moves focus and selects a theme with the radio-group arrow keys", async () => {
    await mount();
    const radios = [...container.querySelectorAll<HTMLButtonElement>('[role="radio"]')];
    expect(radios.map((radio) => radio.tabIndex)).toEqual([0, -1, -1]);
    await act(async () => radios[0].dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true, cancelable: true })));
    expect(props.onChange).toHaveBeenCalledWith(expect.objectContaining({theme: "dark"}));
    expect(document.activeElement).toBe(radios[1]);
  });

  it("opens Permissions from filtered window layouts and clears the filter", async () => {
    props.accessibilityPermission = {...props.accessibilityPermission, supported: true};
    await mount();
    await search("layouts");
    expect(navigation()).toEqual(["Window Management"]);
    const permission = container.querySelector<HTMLButtonElement>(".settings-inline-permission")!;
    await act(async () => permission.click());
    expect(searchInput().value).toBe("");
    expect(container.querySelector('[aria-current="page"]')?.textContent).toBe("Permissions");
  });

});

it("discovers dictation and exposes shared shortcut registration failures", async () => {
  props.commandHotkeyError = "Shortcut registration conflict";
  await mount();
  await search("dictation");
  expect(navigation()).toContain("Dictation");
  expect(container.querySelector('[role="alert"]')?.textContent).toBe("Shortcut registration conflict");
  expect(container.querySelector('[aria-label="Global shortcut for Dictation"]')).not.toBeNull();
});

it("shows both enhancement profiles without usage or an inactive prompt shortcut", async () => {
  await mount();
  await clickSection("Dictation");
  const prompt = container.querySelector('[aria-label="Global shortcut for Structure prompt"]');
  const ordinary = container.querySelector('[aria-label="Global shortcut for Dictation"]');
  expect(prompt).toBeNull(); expect(ordinary).not.toBeNull();
  expect(container.querySelector('[aria-label="Structure prompt"]')).not.toBeNull();
  expect(container.querySelector('[aria-label="Refine speech"]')).not.toBeNull();
  expect(container.querySelector('[aria-label="AI usage"]')).toBeNull();
});

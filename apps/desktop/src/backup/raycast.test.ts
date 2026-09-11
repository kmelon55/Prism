import { beforeAll, describe, expect, it, vi } from "vitest";
import { webcrypto, createCipheriv, createHash, scryptSync } from "node:crypto";
import { gzipSync } from "node:zlib";
import { Buffer, Blob as NodeBlob } from "node:buffer";
import { decodeRaycastFile } from "./raycastFile";
import { buildRaycastPlan, canonicalHotkey, raycastHotkey, resolveRaycastCommand, type ImportContext } from "./raycastPlan";

const classic = {
  builtin_package_snippets: { snippets: [{ name: "Greeting", text: "Hello", keyword: ";hello" }] },
  builtin_package_quicklinks: { quicklinks: [{ name: "Search", url: "https://example.com/?q={Query}" }] },
  builtin_package_rootSearch: { rootSearch: [
    { key: "builtin_command_windowManagement_leftHalf", hotkey: "control-option-123", searchTerms: "left" },
    { key: "builtin_command_windowManagement_rightHalf", hotkey: "control-option-124" },
    { path: "/Applications/Example.app", hotkey: "command-shift-0", searchTerms: "ex" },
    { key: "extension_unknown", hotkey: "command-1" },
  ] },
};
const context: ImportContext = { apps: [{ id: "example", name: "Example", path: "/Applications/Example.app", platform: "macos", rankingBoost: 0 }], entries: [], aliases: {}, hotkeys: {}, disabled: [] };
const encode = (value: unknown) => new TextEncoder().encode(JSON.stringify(value));
beforeAll(() => { vi.stubGlobal("crypto", webcrypto); vi.stubGlobal("Blob", NodeBlob); });
describe("Raycast export decoding", () => {
  it("reads plain and gzipped classic exports", async () => {
    expect(await decodeRaycastFile(encode(classic))).toEqual(classic);
    expect(await decodeRaycastFile(new Uint8Array(gzipSync(encode(classic))))).toEqual(classic);
  });
  it("decrypts classic CBC without trimming the export password", async () => {
    const password = " password with spaces "; const iv = Buffer.alloc(16, 19);
    const cipher = createCipheriv("aes-256-cbc", createHash("sha256").update(password).digest(), iv);
    const file = new Uint8Array(Buffer.concat([iv, cipher.update(gzipSync(encode(classic))), cipher.final()]));
    await expect(decodeRaycastFile(file)).rejects.toMatchObject({ code: "password" });
    await expect(decodeRaycastFile(file, password.trim())).rejects.toMatchObject({ code: "decrypt" });
    expect(await decodeRaycastFile(file, password)).toEqual(classic);
  });
  it.each([12, 16])("decrypts a v2 gzip envelope with a %i-byte GCM IV", async length => {
    const data = { snippets: { snippets: [{ title: "Sample", text: "Content" }] }, settings: { commands: [] } };
    const iv = Buffer.alloc(length, 12), salt = Buffer.alloc(16, 31), password = "export password";
    const cipher = createCipheriv("aes-256-gcm", scryptSync(password, salt, 32), iv);
    const encrypted = Buffer.concat([cipher.update(gzipSync(encode(data))), cipher.final()]);
    const envelope = { schemaVersion: 2, data: encrypted.toString("hex"), encryption: { iv: iv.toString("hex"), salt: salt.toString("hex"), authTag: cipher.getAuthTag().toString("hex") } };
    const file = new Uint8Array(gzipSync(encode(envelope)));
    expect(await decodeRaycastFile(file, password)).toEqual(data);
    await expect(decodeRaycastFile(file, "wrong")).rejects.toMatchObject({ code: "decrypt" });
    envelope.encryption.authTag = "00".repeat(16);
    await expect(decodeRaycastFile(encode(envelope), password)).rejects.toMatchObject({ code: "decrypt" });
  });
  it("rejects newer versions, malformed files, and decompression bombs", async () => {
    await expect(decodeRaycastFile(encode({ schemaVersion: 99, data: "" }))).rejects.toMatchObject({ code: "version" });
    await expect(decodeRaycastFile(encode({ schemaVersion: 1, data: "xz" }))).rejects.toMatchObject({ code: "invalid" });
    await expect(decodeRaycastFile(new Uint8Array(gzipSync(Buffer.alloc(21 * 1024 * 1024))))).rejects.toMatchObject({ code: "size" });
  });
});
describe("Raycast migration review", () => {
  it.each([
    ["sleep", "system:sleep"], ["sleepDisplays", "system:sleep-displays"],
    ["restart", "system:restart"], ["shutDown", "system:shutdown"], ["logOut", "system:log-out"],
  ])("maps classic and package-qualified %s with readable preview titles", (source, target) => {
    for (const key of [`builtin_command_${source}`, `c:r:system::*::${source}`, `c:r:systemActions::*::${source}`]) {
      const rows = buildRaycastPlan({ settings: { commands: [{ id: key, hotkey: "control-option-0", alias: source }] } }, context);
      expect(rows).toHaveLength(2);
      expect(rows.every(row => row.commandId === target && !row.reason && !row.conflict && row.title !== key)).toBe(true);
    }
  });
  it.each([
    ["clipboardHistory", "clipboardHistory", "clipboard:open-history"],
    ["emoji", "searchEmoji", "prism:emoji"], ["fileSearch", "searchFiles", "prism:files"],
    ["snippets", "searchSnippets", "prism:snippets"], ["quicklinks", "searchQuicklinks", "prism:links"],
    ["raycastPreferences", "openPreferences", "prism:preferences"], ["open-ai", "aiChat", "prism:ai-chat"],
  ])("maps the existing %s capability", (pkg, command, target) => {
    expect(resolveRaycastCommand(`c:r:${pkg}::*::${command}`, "", [])).toBe(target);
  });
  it("never maps extensions, wrong packages, prototype keys or force variants to power actions", () => {
    for (const key of ["c:e:system::*::restart", "c:r:snippets::*::restart", "c:r:unknown::*::sleep", "c:r:__proto__::*::restart", "c:r:system::*::constructor", "builtin_command_forceRestart", "c:r:system::*::restartWithoutConfirmation"]) {
      expect(resolveRaycastCommand(key, "", [])).toBeUndefined();
    }
  });
  it("keeps power command conflicts, disabled states and platform limitations visible", () => {
    const data = { settings: { commands: [{ id: "builtin_command_restart", alias: "reboot", hotkey: "command-0" }] } };
    expect(buildRaycastPlan(data, { ...context, disabled: ["system:restart"] }).every(row => row.reason === "Command is disabled in Prism")).toBe(true);
    for (const platform of ["windows", "linux"] as const) {
      expect(buildRaycastPlan(data, { ...context, platform }).every(row => !row.reason)).toBe(true);
    }
    expect(buildRaycastPlan(data, { ...context, platform: "unsupported" }).every(row => row.reason === "Command is unavailable on this platform")).toBe(true);
    const rows = buildRaycastPlan(data, { ...context, hotkeys: { "system:restart": "Super+R" }, aliases: { "system:restart": "old" } });
    expect(rows.every(row => row.conflict && row.before)).toBe(true);
  });
  it("maps windows, installed applications, aliases and quicklink queries", () => {
    const plan = buildRaycastPlan(classic, context);
    expect(plan.find(item => item.commandId === "window:left-half" && item.category === "hotkeys")?.value).toBe("Control+Alt+Left");
    expect(plan.find(item => item.commandId === "native:example" && item.category === "aliases")).toMatchObject({ value: "ex", title: "Example" });
    expect(plan.find(item => item.category === "quicklinks")?.value).toBe("https://example.com/?q={query}");
    expect(plan.find(item => item.title === "extension_unknown")?.reason).toBeTruthy();
  });
  it("keeps conflicts and marks disabled commands, unsupported placeholders, and absent apps", () => {
    const plan = buildRaycastPlan(classic, { ...context, apps: [], hotkeys: { "window:left-half": "Super+K" }, disabled: ["window:right-half"] });
    expect(plan.find(item => item.commandId === "window:left-half" && item.category === "hotkeys")).toMatchObject({ conflict: true, before: "Super+K" });
    expect(plan.find(item => item.commandId === "window:right-half")?.reason).toBe("Command is disabled in Prism");
    expect(plan.find(item => item.title === "Example.app")?.reason).toBeTruthy();
    const snippets = buildRaycastPlan([{ name: "Unsupported", text: "Hi {cursor}" }, { name: "No trigger", text: "Hello", keyword: "hello" }], context);
    expect(snippets[0].reason).toBe("Unsupported placeholder");
    expect(snippets[1].entry?.keyword).toBeUndefined();
    expect(snippets[2].reason).toContain("prefix");
  });
  it("detects duplicate imports, equivalent accelerators and rejects dangerous URLs", () => {
    const first = buildRaycastPlan(classic, context);
    const second = buildRaycastPlan(classic, { ...context, entries: first.flatMap(item => item.entry ? [item.entry] : []), hotkeys: { another: "Alt+Control+Left" } });
    expect(second.filter(item => item.entry).every(item => item.conflict)).toBe(true);
    expect(second.find(item => item.category === "hotkeys" && item.commandId === "window:left-half")?.conflict).toBe(true);
    expect(canonicalHotkey("Command+Shift+K")).toBe(canonicalHotkey("Shift+Super+k"));
    expect(raycastHotkey("unknown-command-0")).toBeUndefined();
    expect(buildRaycastPlan([{ name: "Bad", link: "javascript:alert(1)" }], context)[0].reason).toBe("Unsupported link");
  });
  it("reads v2 physical hotkeys and refuses multi-step shortcuts", () => {
    const key = { kind: { type: "SingleStep", shortcut: { modifiers: [{ modifier: "Hyper" }], key: { type: "LayoutIndependent", code: 123 } } } };
    const plan = buildRaycastPlan({ settings: { commands: [{ id: "c:r:windowManagement::*::leftHalf", macosHotkey: key, alias: "left" }] } }, context);
    expect(plan[0]).toMatchObject({ commandId: "window:left-half", value: "Control+Alt+Shift+Super+Left" });
    expect(raycastHotkey({ kind: { ...key.kind, type: "MultiStep" } })).toBeUndefined();
  });
});

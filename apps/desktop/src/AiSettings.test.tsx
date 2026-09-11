import { act, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AiSettings } from "./AiSettings";
import { aiSelectionKey, formatAiPrice, type AiSelection } from "./providers/ai";
const native = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: native.invoke }));
const models = [
  { id: "creator/fast", name: "Fast Chat", contextWindow: 128000, inputPrice: 0, outputPrice: 0.3 },
  { id: "other/smart", name: "Smart Chat", contextWindow: 256000, inputPrice: 3, outputPrice: 15, pricingVariable: true },
  { id: "other/unknown", name: "Unknown price", contextWindow: null, inputPrice: null, outputPrice: null },
];
let root: Root;
let container: HTMLDivElement;
let persisted: AiSelection | null;
let hasKey: boolean;
async function handle(command: string, args: Record<string, any> = {}) {
  if (command === "ai_get_selection") { persisted ??= args.legacy; return persisted; }
  if (command === "ai_set_selection") { persisted = args.selection; return persisted; }
  if (command === "ai_key_info") return { configured: hasKey, maskedKey: hasKey ? "•••• •••• 1234" : null };
  if (command === "ai_save_key") { hasKey = true; return { configured: true, maskedKey: "•••• •••• 1234" }; }
  if (command === "ai_delete_key") { hasKey = false; return; }
  if (command === "ai_list_models") return models;
}
beforeEach(() => {
  Object.defineProperty(navigator,"language",{configurable:true,value:"ko-KR"});
  localStorage.clear(); persisted = null; hasKey = true;
  native.invoke.mockReset().mockImplementation(handle);
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); });
async function mount(nativeRuntime = true) { await act(async () => root.render(<StrictMode><AiSettings nativeRuntime={nativeRuntime} /></StrictMode>)); }
function button(label: string) { return [...container.querySelectorAll("button")].find((b) => b.getAttribute("aria-label") === label || b.textContent?.trim() === label)!; }
async function click(label: string) { await act(async () => button(label).click()); }
async function type(selector: string, value: string) {
  await act(async () => {
    const input = container.querySelector<HTMLInputElement>(selector)!;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}
describe("AI connection settings", () => {
  it("shows prices, filters locally, saves on click and restores the native selection after storage is cleared", async () => {
    await mount();
    expect(native.invoke).toHaveBeenCalledWith("ai_list_models", { provider: "vercel" });
    expect(container.querySelector(".ai-model-list")).toBeNull();
    await click("기본 모델 변경");
    expect(container.textContent).toContain("$0"); expect(container.textContent).toContain("$15*"); expect(container.textContent).toContain("미제공");
    await type('input[type="search"]', "smart");
    expect(container.querySelectorAll(".ai-model-option")).toHaveLength(1);
    await click("Smart Chat 선택");
    expect(persisted).toEqual({ provider: "vercel", model: "other/smart", modelName: "Smart Chat" });
    await act(async () => root.unmount()); localStorage.clear(); root = createRoot(container); await mount();
    expect(container.querySelector(".ai-current-model")?.textContent).toContain("Smart Chat");
    await click("기본 모델 변경");
    expect(button("Smart Chat 선택").getAttribute("aria-pressed")).toBe("true");
    expect(native.invoke.mock.calls.some(([command]) => command === "ai_chat")).toBe(false);
  });
  it("saves keys only to native storage, displays the masked saved key, and loads authenticated models", async () => {
    hasKey = false; await mount(); await click("OpenAI");
    expect(native.invoke.mock.calls.filter(([command, args]) => command === "ai_list_models" && args.provider === "openai")).toHaveLength(0);
    await type('input[type="password"]', "fixture-secret-1234"); await click("키 저장");
    expect(native.invoke).toHaveBeenCalledWith("ai_save_key", { provider: "openai", key: "fixture-secret-1234" });
    expect(native.invoke).toHaveBeenCalledWith("ai_list_models", { provider: "openai" });
    expect(JSON.stringify(localStorage)).not.toContain("fixture-secret");
    expect(container.querySelector('input[type="password"]')).toBeNull();
    expect(container.querySelector('[aria-label="저장된 API 키"]')?.textContent).toBe("•••• •••• 1234");
    await click("삭제"); expect(container.textContent).toContain("저장된 키 없음");
  });
  it("ignores late catalog and key responses after changing provider", async () => {
    let finish: (value: unknown) => void = () => {};
    native.invoke.mockImplementation((command: string, args: Record<string, any>) => {
      if (command === "ai_list_models" && args.provider === "vercel") return new Promise((resolve) => { finish = resolve; });
      if (command === "ai_list_models") return Promise.resolve([{ id: "router/model", name: "Router model", contextWindow: null }]);
      return handle(command, args);
    });
    await mount(); await click("OpenRouter"); await click("기본 모델 변경"); await act(async () => finish(models));
    expect(container.textContent).toContain("Router model"); expect(container.textContent).not.toContain("Fast Chat");
  });
  it("refreshes the catalog without clearing saved key, key edits, or the current model", async () => {
    persisted = { provider: "vercel", model: "creator/fast", modelName: "Fast Chat" };
    await mount(); await click("변경"); await type('input[type="password"]', "new-fixture-key");
    const calls = native.invoke.mock.calls.filter(([command]) => command === "ai_key_info").length;
    native.invoke.mockImplementation(async (command: string, args: Record<string, any>) => { if (command === "ai_list_models") throw "모델 조회 실패"; return handle(command, args); });
    await click("기본 모델 변경"); await click("모델 목록 새로고침");
    expect(container.textContent).toContain("모델 조회 실패");
    expect(container.querySelector<HTMLInputElement>('input[type="password"]')!.value).toBe("new-fixture-key");
    expect(container.querySelector(".ai-current-model")?.textContent).toContain("Fast Chat");
    expect(container.textContent).toContain("키 저장됨");
    expect(native.invoke.mock.calls.filter(([command]) => command === "ai_key_info")).toHaveLength(calls);
    native.invoke.mockImplementation(handle); await click("모델 목록 새로고침"); expect(container.textContent).not.toContain("모델 조회 실패");
  });
  it("keeps a failed key save recoverable and never marks it saved", async () => {
    hasKey = false;
    native.invoke.mockImplementation(async (command: string, args: Record<string, any>) => { if (command === "ai_save_key") throw "키체인 오류"; return handle(command, args); });
    await mount(); await type('input[type="password"]', "fixture-secret"); await click("키 저장");
    expect(container.textContent).toContain("키체인 오류"); expect(container.textContent).toContain("저장된 키 없음");
    expect(container.querySelector<HTMLInputElement>('input[type="password"]')!.value).toBe("fixture-secret");
  });
  it("retains the last persisted model if a replacement fails and allows selection before adding a key", async () => {
    hasKey = false; await mount(); await click("기본 모델 변경"); await click("Fast Chat 선택");
    expect(persisted?.model).toBe("creator/fast");
    native.invoke.mockImplementation(async (command: string, args: Record<string, any>) => { if (command === "ai_set_selection") throw "디스크 저장 실패"; return handle(command, args); });
    await click("기본 모델 변경"); await click("Smart Chat 선택");
    expect(button("Smart Chat 선택").getAttribute("aria-pressed")).toBe("false");
    expect(button("Fast Chat 선택").getAttribute("aria-pressed")).toBe("true");
    expect(container.textContent).toContain("디스크 저장 실패");
  });
  it("sorts by price with unavailable prices last and keeps zero distinct from missing", async () => {
    await mount(); await click("기본 모델 변경"); await click("입력");
    expect([...container.querySelectorAll(".ai-model-option")].map((entry) => entry.getAttribute("aria-label"))).toEqual(["Fast Chat 선택", "Smart Chat 선택", "Unknown price 선택"]);
    expect(formatAiPrice(null)).toBe("미제공"); expect(formatAiPrice(0)).toBe("$0"); expect(formatAiPrice(0.00005)).toBe("<$0.0001");
  });
  it("does not call native APIs or pretend to load models in browser preview", async () => {
    await mount(false); expect(native.invoke).not.toHaveBeenCalled();
    expect(button("키 저장").disabled).toBe(true); expect(container.querySelectorAll(".ai-model-option")).toHaveLength(0);
  });
});

it("persists tool permissions and only accepts folders returned by the native picker",async()=>{
  let settings={webSearch:false,localFiles:false,maxOutputTokens:16384,folders:[] as {id:string;path:string}[]};
  native.invoke.mockImplementation(async(command:string,args:any)=>{
    if(command==="ai_get_tools")return settings;
    if(command==="ai_set_tools"){settings={...settings,...args};return settings;}
    if(command==="ai_add_folder"){settings={...settings,folders:[{id:"fixture",path:"/fixture/docs"}]};return settings;}
    if(command==="ai_remove_folder"){settings={...settings,folders:[]};return settings;}
    return handle(command,args);
  });
  await mount();
  await act(async()=>container.querySelector<HTMLInputElement>('[aria-label="웹 검색 허용"]')!.click());
  expect(settings.webSearch).toBe(true);
  expect(native.invoke).toHaveBeenCalledWith("ai_set_tools",{webSearch:true,localFiles:false,maxOutputTokens:16384});
  await click("허용 폴더 추가");
  expect(container.textContent).toContain("/fixture/docs");
  expect(native.invoke).toHaveBeenCalledWith("ai_add_folder",{locale:"ko"});
  await click("/fixture/docs 허용 취소");expect(settings.folders).toHaveLength(0);
  await act(async()=>root.unmount());root=createRoot(container);await mount();
  expect(container.querySelector<HTMLInputElement>('[aria-label="웹 검색 허용"]')?.checked).toBe(true);
});

it("does not unlock the Keychain on mount or focus and loads OpenAI models after explicit approval",async()=>{
  persisted={provider:"openai",model:"fixture-model"};
  let unlocked=false;
  native.invoke.mockImplementation(async(command:string,args:any)=>{
    if(command==="ai_key_info")return {configured:true,maskedKey:unlocked?"•••• 1234":null,unlocked};
    if(command==="ai_unlock_key"){unlocked=true;return {configured:true,maskedKey:"•••• 1234",unlocked:true};}
    return handle(command,args);
  });
  await mount();
  for(let i=0;i<3;i++)await act(async()=>window.dispatchEvent(new Event("focus")));
  expect(native.invoke.mock.calls.some(([command])=>command==="ai_unlock_key"||command==="ai_list_models")).toBe(false);
  expect(container.textContent).toContain("macOS 키체인에 보관됨");
  await click("키 사용 허용");
  expect(native.invoke.mock.calls.filter(([command])=>command==="ai_unlock_key")).toHaveLength(1);
  expect(native.invoke).toHaveBeenCalledWith("ai_list_models",{provider:"openai"});
  expect(container.querySelector('[aria-label="저장된 API 키"]')?.textContent).toBe("•••• 1234");
});
it("keeps a canceled Keychain approval explicit instead of retrying on window focus",async()=>{
  native.invoke.mockImplementation(async(command:string,args:any)=>{
    if(command==="ai_key_info")return {configured:true,maskedKey:null,unlocked:false};
    if(command==="ai_unlock_key")throw "접근을 취소했습니다.";
    return handle(command,args);
  });
  await mount();await click("키 사용 허용");
  for(let i=0;i<3;i++)await act(async()=>window.dispatchEvent(new Event("focus")));
  expect(native.invoke.mock.calls.filter(([command])=>command==="ai_unlock_key")).toHaveLength(1);
  expect(container.textContent).toContain("접근을 취소했습니다.");
  expect(button("키 사용 허용").disabled).toBe(false);
});


it("opens the selector from the current model and closes only the popup on Escape",async()=>{
  await mount();
  expect(container.querySelector('[role="dialog"]:not([inert])')).toBeNull();
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 250)); });
  expect(container.querySelector('[role="dialog"]')).toBeNull();
  expect(container.querySelector('.ai-current-model [aria-label="기본 모델 변경"]')).not.toBeNull();
  await click("기본 모델 변경");
  const search=container.querySelector<HTMLInputElement>('[aria-label="모델 검색"]')!;
  expect(document.activeElement).toBe(search);
  await act(async()=>search.dispatchEvent(new KeyboardEvent("keydown",{key:"ArrowDown",bubbles:true,cancelable:true})));
  expect(document.activeElement).toBe(button("Fast Chat 선택"));
  await act(async()=>document.activeElement!.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true,cancelable:true})));
  expect(container.querySelector('[role="dialog"]:not([inert])')).toBeNull();
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 250)); });
  expect(container.querySelector('[role="dialog"]')).toBeNull();
  expect(document.activeElement).toBe(button("기본 모델 변경"));
  await click("기본 모델 변경");await click("Fast Chat 선택");
  expect(container.querySelector('[role="dialog"]:not([inert])')).toBeNull();
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 250)); });
  expect(container.querySelector('[role="dialog"]')).toBeNull();
  expect(container.querySelector('.ai-current-model-copy')?.textContent).toContain("Fast Chat");
});

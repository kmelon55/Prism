import { act, StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { saveAiSelection } from "./providers/ai";
import type { ChatSession } from "./providers/aiHistory";
import { AiChat } from "./AiChat";
const native = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: native.invoke, Channel: class { onmessage?: (event: {text:string})=>void } }));
let root: Root;
let container: HTMLDivElement;
let history: Map<string, ChatSession>;
const close = vi.fn();
const openSettings = vi.fn();
const base = async (command: string, args: any = {}) => {
  if (command === "ai_get_selection") return JSON.parse(localStorage.getItem("prism.ai.selection.v1") ?? "null");
  if (command === "ai_load_history") return [...history.values()];
  if (command === "ai_save_session") { history.set(args.session.id, structuredClone(args.session)); return args.session; }
  if (command === "ai_delete_session") { history.delete(args.sessionId); return; }
  if (command === "ai_key_status") return true;
  if (command === "ai_chat") return "테스트 답변";
};
beforeEach(() => {
  Object.defineProperty(navigator,"language",{configurable:true,value:"ko-KR"});
  localStorage.clear(); close.mockReset(); openSettings.mockReset(); history = new Map();
  localStorage.setItem("prism.ai.selection.v1", JSON.stringify({ provider: "openai", model: "fixture-model" }));
  native.invoke.mockReset().mockImplementation(base);
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); });
async function mount(nativeRuntime = true, visible = true, entryDraft?: { id: number; text: string }, reduceMotion = true) { await act(async () => root.render(<StrictMode><AiChat reduceMotion={reduceMotion} visible={visible} nativeRuntime={nativeRuntime} entryDraft={entryDraft} onClose={close} onOpenSettings={openSettings} /></StrictMode>)); }
function button(label: string) { return [...container.querySelectorAll("button")].find((b) => b.getAttribute("aria-label") === label || b.textContent === label)!; }
async function click(label: string) { await act(async () => button(label).click()); }
async function type(target: HTMLInputElement | HTMLTextAreaElement, value: string) {
  await act(async () => {
    const proto = target instanceof HTMLInputElement ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
    Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(target, value);
    target.dispatchEvent(new Event("input", { bubbles: true }));
  });
}
const composer = () => container.querySelector("textarea")!;
const chatCalls = () => native.invoke.mock.calls.filter(([command]) => command === "ai_chat");
describe("AI chat workspace with mocked native IPC", () => {
  it("does not access keys or send requests while closed or in browser preview", async () => {
    await mount(true, false); expect(native.invoke).not.toHaveBeenCalled();
    await mount(false); expect(native.invoke).not.toHaveBeenCalled();
    expect(container.textContent).toContain("브라우저 미리보기");
    expect(container.querySelector('input[type="password"]')).toBeNull();
    await click("AI 설정 열기"); expect(openSettings).toHaveBeenCalledOnce();
  });
  it("opens settings instead of collecting credentials inside the chat", async () => {
    native.invoke.mockImplementation((command: string, args: any) => command === "ai_key_status" ? Promise.resolve(false) : base(command,args));
    await mount(); await click("AI 설정 열기");
    expect(openSettings).toHaveBeenCalledOnce(); expect(chatCalls()).toHaveLength(0);
  });
  it("moves a palette query into a fresh draft without sending and ignores composition Enter", async () => {
    await mount(true, true, {id:1,text:"안녕하세요"});
    expect(composer().value).toBe("안녕하세요"); expect(chatCalls()).toHaveLength(0);
    for (const init of [{ isComposing: true }, { keyCode: 229 }, { shiftKey: true }]) {
      await act(async () => composer().dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true, ...init })));
    }
    expect(chatCalls()).toHaveLength(0);
    await act(async () => composer().dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })));
    expect(chatCalls()).toHaveLength(1); expect(container.textContent).toContain("테스트 답변");
    expect([...history.values()][0].messages).toHaveLength(2);
  });
  it("preserves the failed question on disk and exposes status details with explicit retry", async () => {
    native.invoke.mockImplementation(async (command: string, args: any) => { if (command === "ai_chat") throw "모델 서버가 응답하지 않습니다.\nVercel AI Gateway · HTTP 503\n요청 ID: fixture"; return base(command,args); });
    await mount(); await type(composer(), "다시 보낼 질문"); await click("메시지 전송");
    expect(composer().value).toBe("다시 보낼 질문"); expect(container.querySelectorAll("article")).toHaveLength(0);
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("HTTP 503");
    expect([...history.values()][0].draft).toBe("다시 보낼 질문"); expect(chatCalls()).toHaveLength(1);
    await click("다시 보내기"); expect(chatCalls()).toHaveLength(2);
  });
  it("prevents duplicate sends, cancels by request ID, and retains the draft on reopen", async () => {
    let rejectRequest: (error: string) => void = () => {};
    native.invoke.mockImplementation((command: string, args: any) => {
      if (command === "ai_chat") return new Promise((_, reject) => { rejectRequest = reject; });
      if (command === "ai_cancel") { rejectRequest("요청을 중지했습니다."); return Promise.resolve(); }
      return base(command,args);
    });
    await mount(); await type(composer(), "중지할 질문"); await click("메시지 전송");
    await act(async () => container.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })));
    expect(chatCalls()).toHaveLength(1);
    await click("응답 중지"); expect(native.invoke).toHaveBeenCalledWith("ai_cancel", { requestId: chatCalls()[0][1].requestId });
    expect(composer().value).toBe("중지할 질문");
    await mount(true, false); await mount(); expect(composer().value).toBe("중지할 질문");
  });
  it("keeps completed sessions bound to their original provider and uses updated settings for a new session", async () => {
    await mount(); await type(composer(), "private question"); await click("메시지 전송");
    await act(async () => saveAiSelection({ provider: "openrouter", model: "creator/chat" }));
    expect(container.querySelectorAll("article")).toHaveLength(2);
    await type(composer(), "follow up"); await click("메시지 전송");
    expect(chatCalls()[1][1].provider).toBe("openai");
    await click("새 대화"); await type(composer(), "new question"); await click("메시지 전송");
    expect(chatCalls()[2][1].provider).toBe("openrouter");
    expect(chatCalls()[2][1].messages).toHaveLength(1);
  });
  it("restores sessions after remount, switches history and deletes only after explicit confirmation", async () => {
    await mount(); await type(composer(), "First question"); await click("메시지 전송");
    await click("새 대화"); await type(composer(), "Second question"); await click("메시지 전송");
    expect(history.size).toBe(2);
    await act(async () => root.unmount()); root = createRoot(container); await mount();
    expect(container.querySelectorAll(".ai-session")).toHaveLength(2);
    await act(async () => [...container.querySelectorAll<HTMLButtonElement>(".ai-session")].find(b=>b.textContent?.includes("First question"))!.click());
    expect(container.querySelector(".ai-messages")?.textContent).toContain("First question");
    await click("현재 대화 삭제"); expect(history.size).toBe(2); await click("삭제"); expect(history.size).toBe(1);
    expect(container.querySelector(".ai-messages")?.textContent).toContain("Second question");
  });
  it("does not send when the question cannot be saved, and preserves the recoverable draft", async () => {
    native.invoke.mockImplementation(async (command: string,args:any) => { if(command === "ai_save_session") throw "디스크 저장 실패"; return base(command,args); });
    await mount(); await type(composer(), "Save me first"); await click("메시지 전송");
    expect(chatCalls()).toHaveLength(0); expect(composer().value).toBe("Save me first"); expect(container.textContent).toContain("디스크 저장 실패");
  });
  it("renders markdown without executing HTML or loading remote images", async () => {
    native.invoke.mockImplementation(async (command:string,args:any) => command === "ai_chat" ? "## Heading\n\n**Bold**\n\n```js\nconst n = 1;\n```\n\n![tracker](https://example.com/pixel)\n<script>alert(1)</script>" : base(command,args));
    await mount(); await type(composer(),"Format please"); await click("메시지 전송");
    expect(container.querySelector(".ai-markdown h2")?.textContent).toBe("Heading"); expect(container.querySelector("pre code")?.textContent).toContain("const n = 1");
    expect(container.querySelector(".ai-markdown img")).toBeNull(); expect(container.querySelector(".ai-markdown script")).toBeNull();
  });
});

it("keeps the departing conversation inert while the new composer receives focus", async () => {
  await mount(true, true, { id: 1, text: "First draft" }, false);
  expect(container.querySelectorAll("textarea")).toHaveLength(1);
  await click("새 대화");
  const outgoing = container.querySelector('.ai-conversation[inert]');
  const incoming = container.querySelector('.ai-conversation:not([inert])');
  expect(outgoing?.getAttribute("aria-hidden")).toBe("true");
  expect(outgoing?.querySelector("textarea")?.value).toBe("First draft");
  expect(incoming?.querySelector("textarea")?.value).toBe("");
  expect(document.activeElement).toBe(incoming?.querySelector("textarea"));
  expect(chatCalls()).toHaveLength(0);
});

it("changes the model in the composer without losing messages and persists before sending", async () => {
  const model = {id:"zai/glm-5.3-flash",name:"GLM 5.3 Flash",inputPrice:0.15,outputPrice:0.5,contextWindow:1000000};
  native.invoke.mockImplementation(async(command:string,args:any)=>command==="ai_list_models"?[model]:base(command,args));
  await mount();await type(composer(),"Existing question");await click("메시지 전송");
  await click("대화 모델 변경");
  expect(container.textContent).toContain("$0.15 / $0.5");
  await click("GLM 5.3 Flash 사용");
  expect(container.querySelectorAll("article")).toHaveLength(2);
  expect(container.querySelector('[aria-label="대화 모델 변경"]')?.textContent).toContain("GLM 5.3 Flash");
  expect([...history.values()][0].model).toBe(model.id);
  await type(composer(),"Follow up");await click("메시지 전송");
  expect(chatCalls()[1][1].model).toBe(model.id);expect(chatCalls()[1][1].messages).toHaveLength(3);
});
it("keeps the previous model and displays a failed model-save in the picker",async()=>{
  native.invoke.mockImplementation(async(command:string,args:any)=>{if(command==="ai_list_models")return [{id:"next",name:"Next"}];if(command==="ai_save_session")throw "저장 실패";return base(command,args);});
  await mount();await click("대화 모델 변경");await click("Next 사용");
  expect(container.querySelector('[aria-label="대화 모델 선택"]')?.textContent).toContain("저장 실패");
  expect(container.querySelector('[aria-label="대화 모델 변경"]')?.textContent).toContain("fixture-model");
});
it("requires explicit per-question tool activation and closes model picker on Escape only",async()=>{
  native.invoke.mockImplementation(async(command:string,args:any)=>command==="ai_get_tools"?{webSearch:true,localFiles:true,maxOutputTokens:16384,folders:[{id:"fixture",path:"/fixture"}]}:command==="ai_list_models"?[]:base(command,args));
  await mount();await click("대화 모델 변경");
  await act(async()=>container.querySelector('[aria-label="대화 모델 검색"]')!.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true,cancelable:true})));
  expect(close).not.toHaveBeenCalled();expect(container.querySelector('[aria-label="대화 모델 선택"]')).toBeNull();
  await type(composer(),"plain question");await click("메시지 전송");
  expect(chatCalls()[0][1]).toMatchObject({useWeb:false,useFiles:false});
  await click("이 질문에 웹 검색 사용");await click("이 질문에 로컬 파일 사용");
  await type(composer(),"look it up");await click("메시지 전송");
  expect(chatCalls()[1][1]).toMatchObject({useWeb:true,useFiles:true});
});

function seedSessions(count = 4) {
  const entries: ChatSession[] = Array.from({ length: count }, (_, index) => ({
    id: crypto.randomUUID(), provider: "openai", model: "fixture-model", title: `Conversation ${index + 1}`,
    messages: [{ role: "user", content: `Question ${index + 1}` }, { role: "assistant", content: `Answer ${index + 1}` }],
    draft: "", updatedAt: 100 - index,
  }));
  entries.forEach(session => history.set(session.id, structuredClone(session)));
  return entries;
}
async function shortcut(key: string, options: KeyboardEventInit = {}) {
  await act(async () => composer().dispatchEvent(new KeyboardEvent("keydown", { key, metaKey: true, bubbles: true, cancelable: true, ...options })));
}
const activeTitle = () => container.querySelector('.ai-conversation:not([inert]) .ai-header strong')?.textContent;

it("switches numbered conversations from the composer and saves the outgoing draft", async () => {
  const sessions = seedSessions(); await mount();
  await type(composer(), "Keep my unfinished question");
  for (const key of ["2", "3", "4", "1"]) {
    await shortcut(key);
    expect(activeTitle()).toBe(`Conversation ${key}`);
    expect(document.activeElement).toBe(composer());
  }
  expect(composer().value).toBe("Keep my unfinished question");
  expect(history.get(sessions[0].id)?.draft).toBe("Keep my unfinished question");
  expect(chatCalls()).toHaveLength(0);
  expect(container.querySelector("kbd")).toBeNull();
});

it("searches message bodies and numbers the visible filtered conversations", async () => {
  const entries = seedSessions();
  entries[2].messages[1].content = "회의록에만 있는 검색어";
  history.set(entries[2].id, entries[2]); await mount();
  await type(container.querySelector('input[aria-label="대화 검색"]')!, "검색어");
  expect(container.querySelectorAll(".ai-session")).toHaveLength(1);
  await shortcut("1"); expect(activeTitle()).toBe("Conversation 3");
  await click("새 대화"); expect(container.querySelectorAll(".ai-session")).toHaveLength(4);
});

it("ignores numbered switching during composition, repeats, modifier variants, and deletion confirmation", async () => {
  seedSessions(); await mount();
  for (const options of [{isComposing: true}, {keyCode: 229}, {repeat: true}, {shiftKey: true}, {altKey: true}]) await shortcut("2", options);
  expect(activeTitle()).toBe("Conversation 1");
  await click("현재 대화 삭제");
  expect(button("현재 대화 삭제").closest("[data-tauri-drag-region]")).toBeNull();
  expect(document.activeElement).toBe(button("취소"));
  await shortcut("2"); expect(activeTitle()).toBe("Conversation 1");
  await shortcut("Escape", {metaKey: false});
  expect(container.querySelector('[role="alertdialog"]')).toBeNull();
  expect(close).not.toHaveBeenCalled(); expect(document.activeElement).toBe(composer());
  await shortcut("2", {metaKey: false, ctrlKey: true}); expect(activeTitle()).toBe("Conversation 2");
});

it("retries a failed deletion as deletion and preserves the selected conversation until it succeeds", async () => {
  const entries = seedSessions(2); let attempts = 0;
  native.invoke.mockImplementation(async (command: string, args: any) => {
    if (command === "ai_delete_session" && attempts++ === 0) throw "대화를 삭제하지 못했습니다.";
    return base(command, args);
  });
  await mount(); await click("현재 대화 삭제"); await click("삭제");
  expect(history.size).toBe(2); expect(activeTitle()).toBe("Conversation 1");
  expect(container.querySelector('[role="alertdialog"] [role="alert"]')?.textContent).toContain("삭제하지 못했습니다");
  await click("삭제 다시 시도");
  expect(attempts).toBe(2); expect(history.has(entries[0].id)).toBe(false);
  expect(activeTitle()).toBe("Conversation 2");
  expect(native.invoke.mock.calls.filter(([command]) => command === "ai_save_session")).toHaveLength(0);
});

it("deletes an unselected conversation without replacing the current draft", async () => {
  const entries = seedSessions(2); await mount(); await type(composer(), "Working draft");
  await click("Conversation 2 대화 삭제"); await click("삭제");
  expect(history.has(entries[1].id)).toBe(false); expect(activeTitle()).toBe("Conversation 1");
  expect(composer().value).toBe("Working draft");
});

it("discards a fresh draft before autosave and never resurrects it afterward", async () => {
  vi.useFakeTimers();
  try {
    await mount(); await type(composer(), "Discard this unsaved draft");
    await click("현재 대화 삭제"); await click("삭제");
    await act(async () => vi.advanceTimersByTimeAsync(1000));
    expect(history.size).toBe(0); expect(composer().value).toBe("");
    expect(native.invoke.mock.calls.filter(([command]) => command === "ai_save_session")).toHaveLength(0);
  } finally { vi.useRealTimers(); }
});

it("waits for an in-flight autosave before deletion and prevents repeated deletion", async () => {
  vi.useFakeTimers();
  try {
    const [session] = seedSessions(1); let completeSave: () => void = () => {};
    native.invoke.mockImplementation((command: string, args: any) => {
      if (command === "ai_save_session") return new Promise(resolve => { completeSave = () => { void base(command, args).then(resolve); }; });
      return base(command, args);
    });
    await mount(); await type(composer(), "Pending save");
    await act(async () => vi.advanceTimersByTimeAsync(500));
    await click("현재 대화 삭제"); await click("삭제");
    expect(native.invoke.mock.calls.filter(([command]) => command === "ai_delete_session")).toHaveLength(0);
    await click("삭제 중…");
    await act(async () => completeSave());
    await act(async () => vi.advanceTimersByTimeAsync(1000));
    expect(history.has(session.id)).toBe(false);
    expect(native.invoke.mock.calls.filter(([command]) => command === "ai_delete_session")).toHaveLength(1);
    expect(composer().value).toBe("");
  } finally { vi.useRealTimers(); }
});

it("preserves reading position when an answer arrives and offers a jump to the latest message", async () => {
  seedSessions(1); let completeAnswer: (answer: string) => void = () => {};
  native.invoke.mockImplementation((command: string, args: any) => command === "ai_chat" ? new Promise(resolve => { completeAnswer = resolve; }) : base(command, args));
  await mount(); await type(composer(), "Next question"); await click("메시지 전송");
  const log = container.querySelector<HTMLDivElement>('.ai-messages')!;
  Object.defineProperties(log, {scrollHeight: {value: 2000}, clientHeight: {value: 500}});
  const scrollTo = vi.fn(); log.scrollTo = scrollTo;
  await act(async () => { log.scrollTop = 200; log.dispatchEvent(new Event("scroll", {bubbles: true})); });
  await act(async () => completeAnswer("New answer"));
  expect(scrollTo).not.toHaveBeenCalled();
  await click("최신 메시지로 이동"); expect(scrollTo).toHaveBeenCalledWith({top: 2000, behavior: "auto"});
});

it("streams incremental answers but saves only the acknowledged final turn",async()=>{
 let finish:(text:string)=>void=()=>{};let channel:{onmessage:(event:{text:string})=>void};
 native.invoke.mockImplementation((command:string,args:any)=>{if(command==="ai_chat"){channel=args.onEvent;return new Promise(resolve=>{finish=resolve;});}return base(command,args);});
 await mount();await type(composer(),"Stream this");await click("메시지 전송");
 await act(async()=>channel.onmessage({text:"아직 작성 중"}));
 expect(container.querySelector(".ai-messages")?.textContent).toContain("아직 작성 중");
 expect([...history.values()][0].messages).toHaveLength(0);
 await act(async()=>finish("완료한 답변"));
 expect([...history.values()][0].messages.at(-1)?.content).toBe("완료한 답변");
 await act(async()=>channel.onmessage({text:"늦은 이벤트"}));
 expect(container.textContent).not.toContain("늦은 이벤트");
});
it("edits a previous question in a new unsent conversation while preserving the original",async()=>{
 const [original]=seedSessions(1);await mount();await click("질문 수정");
 expect(history.size).toBe(2);expect(history.get(original.id)?.messages).toEqual(original.messages);
 expect(composer().value).toBe("Question 1");expect(container.querySelectorAll("article")).toHaveLength(0);expect(chatCalls()).toHaveLength(0);
 await type(composer(),"Revised question");await click("메시지 전송");
 expect(chatCalls()[0][1].messages).toEqual([{role:"user",content:"Revised question"}]);
 expect(history.get(original.id)?.messages).toEqual(original.messages);
});
it("regenerates explicitly without overwriting an existing answer",async()=>{
 const [original]=seedSessions(1);await mount();await click("답변 다시 생성");
 expect(chatCalls()).toHaveLength(1);expect(history.size).toBe(2);
 expect(history.get(original.id)?.messages[1].content).toBe("Answer 1");
 expect([...history.values()].find(s=>s.id!==original.id)?.messages[1].content).toBe("테스트 답변");
});
it("renames and pins a conversation durably and retains pin ordering after remount",async()=>{
 const originals=seedSessions(2);await mount();await shortcut("2");await click("대화 이름 변경");
 await type(container.querySelector('input[aria-label="대화 이름"]')!,"계속 사용할 대화");await click("저장");
 await click("대화 고정");expect(history.get(originals[1].id)).toMatchObject({title:"계속 사용할 대화",pinned:true});
 await act(async()=>root.unmount());root=createRoot(container);await mount();
 expect(container.querySelector(".ai-session")?.textContent).toContain("계속 사용할 대화");
});
it("keeps the old title and rename draft after persistence fails",async()=>{
 seedSessions(1);await mount();native.invoke.mockImplementation(async(command:string,args:any)=>{if(command==="ai_save_session")throw "저장 실패";return base(command,args);});
 await click("대화 이름 변경");await type(container.querySelector('input[aria-label="대화 이름"]')!,"새 이름");await click("저장");
 expect(activeTitle()).toBe("Conversation 1");expect(container.querySelector(".ai-session")?.textContent).toContain("Conversation 1");
 expect(container.querySelector<HTMLInputElement>('input[aria-label="대화 이름"]')?.value).toBe("새 이름");
});
it("exports the current conversation through the native save dialog without sending",async()=>{
 seedSessions(1);await mount();await click("대화 내보내기");
 expect(native.invoke).toHaveBeenCalledWith("ai_export_session",{session:expect.objectContaining({title:"Conversation 1"}),locale:"ko"});expect(chatCalls()).toHaveLength(0);
});

it("enables local files from the composer after a folder grant and retries a stale permission snapshot",async()=>{
 let settings={webSearch:false,localFiles:false,maxOutputTokens:16384,folders:[] as {id:string;path:string}[]};
 native.invoke.mockImplementation(async(command,args)=>{
  if(command==="ai_get_tools")return settings;
  if(command==="ai_add_folder"){settings={...settings,localFiles:true,folders:[{id:"docs",path:"/fixture/docs"}]};return settings;}
  return base(command,args);
 });
 await mount();expect(button("이 질문에 로컬 파일 사용").disabled).toBe(false);await click("이 질문에 로컬 파일 사용");
 expect(native.invoke).toHaveBeenCalledWith("ai_add_folder",{locale:"ko"});expect(button("이 질문에 로컬 파일 사용").getAttribute("aria-pressed")).toBe("true");
 await type(composer(),"파일을 읽어줘");await click("메시지 전송");expect(chatCalls().at(-1)?.[1].useFiles).toBe(true);
 await click("이 질문에 로컬 파일 사용");settings={...settings,localFiles:true};await click("이 질문에 로컬 파일 사용");
 expect(native.invoke.mock.calls.filter(([c])=>c==="ai_add_folder")).toHaveLength(1);
});
it("keeps files off after a canceled folder picker and allows retry after a settings read failure",async()=>{
 let fail=false;const settings={webSearch:false,localFiles:true,maxOutputTokens:16384,folders:[]};
 native.invoke.mockImplementation(async(command,args)=>{
  if(command==="ai_get_tools"){if(fail)throw "도구 설정을 읽지 못했습니다.";return settings;}
  if(command==="ai_add_folder")return settings;
  return base(command,args);
 });
 await mount();await click("이 질문에 로컬 파일 사용");expect(button("이 질문에 로컬 파일 사용").getAttribute("aria-pressed")).toBe("false");
 fail=true;await click("이 질문에 로컬 파일 사용");expect(container.textContent).toContain("도구 설정을 읽지 못했습니다.");expect(button("이 질문에 로컬 파일 사용").disabled).toBe(false);
});


function pendingChats() {
  const requests = new Map<string, { args: any; resolve: (value: string) => void; reject: (value: string) => void }>();
  native.invoke.mockImplementation((command: string, args: any) => {
    if (command === "ai_chat") return new Promise<string>((resolve, reject) => requests.set(args.requestId, { args, resolve, reject }));
    if (command === "ai_cancel") { requests.get(args.requestId)?.reject("요청을 중지했습니다."); return Promise.resolve(); }
    return base(command, args);
  });
  return requests;
}
async function chooseConversation(title: string) {
  await act(async () => [...container.querySelectorAll<HTMLButtonElement>(".ai-session")].find(button => button.textContent?.includes(title))!.click());
}
it("retains background streams and completion without overwriting another conversation draft", async () => {
  const requests = pendingChats();
  await mount(); await type(composer(), "Background first"); await click("메시지 전송");
  const first = [...requests.values()][0];
  await click("새 대화"); await type(composer(), "Untouched draft");
  await act(async () => first.args.onEvent.onmessage({ text: "Background partial" }));
  expect(composer().value).toBe("Untouched draft");
  expect(container.querySelector(".ai-messages")?.textContent).not.toContain("Background partial");
  await chooseConversation("Background first");
  expect(container.querySelector(".ai-messages")?.textContent).toContain("Background partial");
  await chooseConversation("Untouched draft");
  await act(async () => first.resolve("Background final"));
  expect(composer().value).toBe("Untouched draft");
  expect([...history.values()].find(session => session.title === "Background first")?.messages[1].content).toBe("Background final");
  await chooseConversation("Background first");
  expect(container.querySelector(".ai-messages")?.textContent).toContain("Background final");
  expect(composer().disabled).toBe(false);
});
it("bounds concurrent sends and cancels only the selected conversation", async () => {
  const requests = pendingChats();
  await mount();
  for (const title of ["First live", "Second live", "Third live"]) {
    await type(composer(), title); await click("메시지 전송"); await click("새 대화");
  }
  await type(composer(), "Fourth draft");
  expect(button("메시지 전송").disabled).toBe(true);
  await act(async () => composer().dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })));
  expect(chatCalls()).toHaveLength(3);
  await chooseConversation("Second live"); await click("응답 중지");
  expect(native.invoke.mock.calls.filter(([command]) => command === "ai_cancel")).toEqual([["ai_cancel", { requestId: [...requests.keys()][1] }]]);
  expect(composer().value).toBe("Second live");
  await chooseConversation("First live"); expect(button("응답 중지")).toBeDefined();
  await chooseConversation("Fourth draft"); expect(button("메시지 전송").disabled).toBe(false);
});
it("keeps inactive errors with their request and permits deleting other inactive conversations", async () => {
  const requests = pendingChats();
  await mount(); await type(composer(), "Failed background"); await click("메시지 전송");
  await click("새 대화"); await type(composer(), "Keep running"); await click("메시지 전송");
  expect(button("Failed background 대화 삭제").disabled).toBe(true);
  await act(async () => [...requests.values()][0].reject("Background provider failed"));
  expect(container.querySelector('[role="alert"]')?.textContent ?? "").not.toContain("Background provider failed");
  await chooseConversation("Failed background");
  expect(container.querySelector('[role="alert"]')?.textContent).toContain("Background provider failed");
  await chooseConversation("Keep running");
  await click("Failed background 대화 삭제"); await click("삭제");
  await act(async () => [...requests.values()][0].args.onEvent.onmessage({ text: "Late deleted update" }));
  expect([...history.values()].some(session => session.title === "Failed background")).toBe(false);
  expect(container.textContent).not.toContain("Late deleted update");
  expect(button("응답 중지")).toBeDefined();
});
it("uses a fresh completed snapshot when a destination finishes during the outgoing save", async () => {
  const requests = pendingChats();
  await mount(); await type(composer(), "Destination"); await click("메시지 전송");
  await click("새 대화"); await type(composer(), "Outgoing draft");
  let finishSave: () => void = () => {};
  native.invoke.mockImplementation((command: string, args: any) => command === "ai_save_session" && args.session.draft === "Outgoing draft"
    ? new Promise<void>(resolve => { finishSave = () => { void base(command, args); resolve(); }; }) : base(command, args));
  await chooseConversation("Destination");
  await act(async () => [...requests.values()][0].resolve("Completed during switch"));
  await act(async () => finishSave());
  expect(container.querySelector(".ai-messages")?.textContent).toContain("Completed during switch");
  expect(composer().value).toBe("");
});
it("ignores old request completion and stream callbacks after unmount and remount", async () => {
  const requests = pendingChats();
  await mount(); await type(composer(), "Old mount"); await click("메시지 전송");
  const previous = [...requests.values()][0];
  // Simulate a provider that does not settle immediately when cancellation is sent.
  native.invoke.mockImplementation((command: string, args: any) => base(command, args));
  await act(async () => root.unmount()); root = createRoot(container); await mount();
  await type(composer(), "New mount draft");
  await act(async () => { previous.args.onEvent.onmessage({ text: "Stale stream" }); previous.resolve("Stale final"); });
  expect(composer().value).toBe("New mount draft");
  expect(container.textContent).not.toContain("Stale final");
  expect([...history.values()].some(session => session.messages.some(message => message.content === "Stale final"))).toBe(false);
});

it("can explicitly resend a cancelled conversation without inheriting its cancellation flag", async () => {
  const requests = pendingChats();
  await mount(); await type(composer(), "Cancel then retry"); await click("메시지 전송");
  await click("응답 중지"); await click("다시 보내기");
  expect(chatCalls()).toHaveLength(2);
  await act(async () => [...requests.values()][1].resolve("Retried successfully"));
  expect(container.querySelector(".ai-messages")?.textContent).toContain("Retried successfully");
  expect([...history.values()][0].messages[1].content).toBe("Retried successfully");
});
it("keeps failed background completion saves recoverable in their own conversation", async () => {
  const requests = pendingChats();
  await mount(); await type(composer(), "Background save"); await click("메시지 전송");
  await click("새 대화"); await type(composer(), "Current draft");
  native.invoke.mockImplementation((command: string, args: any) => command === "ai_save_session" && args.session.title === "Background save" && args.session.messages.length
    ? Promise.reject("Background disk failure") : base(command, args));
  await act(async () => [...requests.values()][0].resolve("Unsaved final"));
  expect(container.textContent).not.toContain("Background disk failure");
  expect(composer().value).toBe("Current draft");
  await chooseConversation("Background save");
  expect(container.textContent).toContain("Background disk failure");
  expect(container.querySelector(".ai-messages")?.textContent).toContain("Unsaved final");
  native.invoke.mockImplementation(base);
  await click("기록 저장·조회 다시 시도");
  expect([...history.values()].find(session => session.title === "Background save")?.messages[1].content).toBe("Unsaved final");
  expect(chatCalls()).toHaveLength(1);
});

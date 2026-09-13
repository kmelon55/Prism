import { t, useLocale, currentLocale } from "./i18n";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { Channel, invoke } from "@tauri-apps/api/core";
import { Pencil, Pin, Download, RotateCcw, ArrowDown, ArrowLeft, ArrowUp, Scan, X, Globe, FolderOpen, SlidersHorizontal, Copy, KeyRound, MessageSquare, Plus, Search, Square, Sparkles, Trash2 } from "lucide-react";
import Markdown from "react-markdown";
import { AnimatePresence, motion } from "motion/react";
import { AiConversationTransition } from "./interaction/AiConversationTransition";
import { AiModelPicker } from "./AiModelPicker";
import { defaultAiTools, getAiTools, setAiTools } from "./providers/aiTools";
import remarkGfm from "remark-gfm";
import { aiErrorText, aiProviders, loadAiSelection, readAiSelection, notifyAiSettingsChanged, watchAiSettings, type AiSelection } from "./providers/ai";
import { downloadChat, forkChatSession, sortChatSessions, deleteChatSession, loadChatHistory, newChatSession, saveChatSession, type ChatImage, type ChatMessage, type ChatSession } from "./providers/aiHistory";
import { queueHistoryOperation } from "./ai/historyQueue";
import { isCompositionKey } from "./interaction/usePaletteKeyboard";

export interface AiChatEntry { id: number; text: string; image?: ChatImage }
const MAX_CONCURRENT_REQUESTS = 3;
interface ConversationRequest { id: string | null; pending: string; streamed: string; question: string; error: string; cancelled?: boolean }
const idleRequest: ConversationRequest = { id: null, pending: "", streamed: "", question: "", error: "", cancelled: false };

const presets = [
  { get label() { return t("요약"); }, get prompt() { return t("다음 내용을 핵심만 간결하게 한국어로 요약해 줘:\n\n"); } },
  { get label() { return t("한국어로 번역"); }, get prompt() { return t("다음 내용을 자연스러운 한국어로 번역해 줘:\n\n"); } },
  { get label() { return t("영어로 번역"); }, get prompt() { return t("다음 내용을 자연스러운 영어로 번역해 줘:\n\n"); } },
  { get label() { return t("문장 다듬기"); }, get prompt() { return t("다음 글의 의미를 유지하면서 자연스럽고 명확하게 다듬어 줘:\n\n"); } },
];
export function AiChat({ visible, nativeRuntime, entryDraft, closing = false, reduceMotion = false, onClose, onOpenSettings }: {
  visible: boolean; nativeRuntime: boolean; closing?: boolean; reduceMotion?: boolean; entryDraft?: AiChatEntry; onClose(): void; onOpenSettings(): void;
}) {
  useLocale();
  const [selection, setSelection] = useState<AiSelection>(readAiSelection);
  const [current, setCurrent] = useState(() => newChatSession(selection));
  const [sessions, setSessions] = useState<ChatSession[]>([]);
  const [historyReady, setHistoryReady] = useState(!nativeRuntime);
  const [historyRevision, setHistoryRevision] = useState(0);
  const [failedEntry, setFailedEntry] = useState<AiChatEntry>();
  const [toolSettings, setToolSettings] = useState(defaultAiTools);
  const [useWeb, setUseWeb] = useState(false);
  const [useFiles, setUseFiles] = useState(false);
  const [filesBusy, setFilesBusy] = useState(false);
  const filesLock = useRef(false);
  const [historyErrors, setHistoryErrors] = useState<Record<string, string>>({});
  const historyError = historyErrors[current.id] ?? historyErrors.load ?? "";
  const [configured, setConfigured] = useState(false);
  const [capturing, setCapturing] = useState(false);
  const captureLock = useRef(false);
  const [checking, setChecking] = useState(false);
  const requests = useRef(new Map<string, ConversationRequest>());
  const [, refreshRequests] = useState(0);
  const [switching, setSwitching] = useState(false);
  const [conversationRevision, setConversationRevision] = useState(0);
  const activeRequest = requests.current.get(current.id) ?? idleRequest;
  const busy = Boolean(activeRequest.id);
  const { pending, streamed, question: streamQuestion, error } = activeRequest;
  const activeCount = [...requests.current.values()].filter(request => request.id).length;
  const [rename,setRename]=useState<string|null>(null);
  const [notice, setNotice] = useState("");
  const [filter, setFilter] = useState("");
  const [deleteTarget, setDeleteTarget] = useState<ChatSession | null>(null);
  const [deleteError, setDeleteError] = useState("");
  const [awayFromBottom, setAwayFromBottom] = useState(false);
  const [configRevision, setConfigRevision] = useState(0);
  const currentRef = useRef(current);
  const sessionsRef = useRef(sessions);
  const deleting = useRef(new Set<string>());
  const mutation = useRef(false);
  const followMessages = useRef(true);
  const cancelDeleteButton = useRef<HTMLButtonElement>(null);
  const versions = useRef(new Map<string, number>());
  const savedVersions = useRef(new Map<string, string>());
  const alive = useRef(true);
  const loaded = useRef(!nativeRuntime);
  const lastEntry = useRef<number | undefined>(undefined);
  const composer = useRef<HTMLTextAreaElement>(null);
  const scroll = useRef<HTMLDivElement>(null);
  const composing = useRef(false);
  const { provider, model, messages, draft } = current;
  const providerName = aiProviders[provider].name;
  const readyToSend = historyReady && nativeRuntime && configured && Boolean(model) && !checking && !capturing && !switching && !deleteTarget;
  const hasSavedSession = sessions.some((session) => session.id === current.id);
  const history = useMemo(() => {
    const query = filter.trim().toLocaleLowerCase();
    if (!query) return sessions;
    const matches = (text: string) => text.toLocaleLowerCase().includes(query);
    return sessions.filter(session => [session.title, session.modelName ?? session.model, session.draft].some(matches) || session.messages.some(message => matches(message.content)));
  }, [sessions, filter]);

  function patchRequest(sessionId: string, patch: Partial<ConversationRequest>) {
    if (!alive.current || deleting.current.has(sessionId)) return;
    requests.current.set(sessionId, { ...(requests.current.get(sessionId) ?? idleRequest), ...patch });
    refreshRequests(value => value + 1);
  }
  function setHistoryError(error: string, sessionId = loaded.current ? currentRef.current.id : "load") {
    if (alive.current) setHistoryErrors(errors => ({ ...errors, [sessionId]: error }));
  }
  function setError(error: string) { patchRequest(currentRef.current.id, { error }); }
  function isRunning(sessionId = currentRef.current.id) { return Boolean(requests.current.get(sessionId)?.id); }
  function replaceCurrent(session: ChatSession) { currentRef.current = session; setCurrent(session); }
  function remember(session: ChatSession) {
    const next = sortChatSessions([session, ...sessionsRef.current.filter((entry) => entry.id !== session.id)]);
    sessionsRef.current = next; if (alive.current) setSessions(next);
  }
  async function persist(session: ChatSession): Promise<boolean> {
    if (!loaded.current || !nativeRuntime || deleting.current.has(session.id)) return true;
    if (!session.messages.length && !session.draft && !session.draftImage && !sessionsRef.current.some((entry) => entry.id === session.id)) return true;
    const snapshot = JSON.stringify(session);
    if (savedVersions.current.get(session.id) === snapshot) return true;
    const version = (versions.current.get(session.id) ?? 0) + 1;
    versions.current.set(session.id, version); remember(session);
    const task = queueHistoryOperation(() => {
      if (alive.current && !deleting.current.has(session.id)) return saveChatSession(session);
    });
    try {
      await task;
      if (!deleting.current.has(session.id)) savedVersions.current.set(session.id, snapshot);
      if (alive.current && versions.current.get(session.id) === version) {
        setHistoryError("", session.id);
      }
      return true;
    } catch (error) {
      if (alive.current) { setHistoryError(aiErrorText(error), session.id); }
      return false;
    }
  }
  function updateDraft(value: string) {
    replaceCurrent({ ...currentRef.current, draft: value, updatedAt: Date.now() });
  }
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
      for (const request of requests.current.values()) if (request.id) void invoke("ai_cancel", { requestId: request.id }).catch(() => {});
      requests.current.clear();
    };
  }, []);
  useEffect(() => {
    if (!visible || !nativeRuntime) return;
    let active = true;
    void getAiTools().then(value => { if (active && value) { setToolSettings(value); if(!value.webSearch)setUseWeb(false); if(!value.localFiles || !value.folders.length)setUseFiles(false); } }).catch(() => { if(active){setUseWeb(false);setUseFiles(false);} });
    return () => {active=false;};
  }, [visible, nativeRuntime, configRevision]);
  useEffect(() => watchAiSettings(() => setConfigRevision((value) => value + 1)), []);
  useEffect(() => {
    if (!notice) return;
    const timer = window.setTimeout(() => setNotice(""), 2200);
    return () => window.clearTimeout(timer);
  }, [notice]);
  useEffect(() => {
    if (!visible || loaded.current || !nativeRuntime) return;
    let active = true;
    void Promise.all([loadAiSelection(true), queueHistoryOperation(() => loadChatHistory())]).then(([next, history]) => {
      if (!active) return;
      if (!Array.isArray(history)) throw t("대화 기록을 읽지 못했습니다.");
      loaded.current = true; setHistoryReady(true); setSelection(next);
      sessionsRef.current = sortChatSessions(history); setSessions(sessionsRef.current);
      history.forEach((session) => savedVersions.current.set(session.id, JSON.stringify(session)));
      replaceCurrent(sessionsRef.current[0] ?? newChatSession(next)); setHistoryErrors({});
    }).catch((error) => { if (active) setHistoryError(aiErrorText(error)); });
    return () => { active = false; };
  }, [visible, nativeRuntime, historyRevision]);
  useEffect(() => {
    if (!visible || !historyReady || isRunning()) return;
    let active = true;
    void loadAiSelection(nativeRuntime).then((next) => {
      if (!active) return;
      setSelection(next);
      const session = currentRef.current;
      if (!session.messages.length && session.provider === selection.provider && session.model === selection.model && (session.provider !== next.provider || session.model !== next.model || session.modelName !== next.modelName)) {
        replaceCurrent({ ...session, ...next });
      }
    }).catch((error) => { if (active) setError(aiErrorText(error)); });
    return () => { active = false; };
  }, [visible, nativeRuntime, configRevision, historyReady, busy]);
  useEffect(() => {
    if (!visible || !nativeRuntime || !historyReady) return;
    let active = true; setChecking(true); setConfigured(false);
    void invoke<boolean>("ai_key_status", { provider }).then((exists) => { if (active) setConfigured(exists); })
      .catch((error) => { if (active) setError(aiErrorText(error)); })
      .finally(() => { if (active) setChecking(false); });
    return () => { active = false; };
  }, [visible, nativeRuntime, provider, configRevision, historyReady]);
  async function acceptEntry(entry: AiChatEntry) {
    if (mutation.current) { setFailedEntry(entry); return; }
    mutation.current = true; setSwitching(true);
    try {
      const ok = await persist(currentRef.current);
      if (!alive.current) return;
      if (ok) { replaceCurrent({ ...newChatSession(selection, entry.text), draftImage: entry.image }); setFailedEntry(undefined); }
      else setFailedEntry(entry);
    } finally { mutation.current = false; if (alive.current) setSwitching(false); }
  }
  useEffect(() => {
    if (!visible || !historyReady || !entryDraft || lastEntry.current === entryDraft.id) return;
    lastEntry.current = entryDraft.id;
    if (entryDraft.text.trim() || entryDraft.image) {
      void acceptEntry(entryDraft);
    }
  }, [visible, historyReady, entryDraft, selection]);
  useEffect(() => {
    if (!historyReady || busy) return;
    const session = current;
    const timer = window.setTimeout(() => { void persist(session); }, 450);
    return () => window.clearTimeout(timer);
  }, [current, historyReady, busy]);
  useEffect(() => { if (visible && historyReady && !busy && !checking && !capturing && !deleteTarget) composer.current?.focus(); }, [visible, historyReady, busy, checking, capturing, current.id, deleteTarget]);
  useEffect(() => { if (deleteTarget) cancelDeleteButton.current?.focus(); }, [deleteTarget, switching]);
  useLayoutEffect(() => {
    const input = composer.current;
    if (!input) return;
    input.style.height = "auto";
    input.style.height = `${Math.min(180, Math.max(44, input.scrollHeight))}px`;
  }, [draft, busy, current.id, visible]);
  useEffect(() => {
    followMessages.current = true; setAwayFromBottom(false);
  }, [current.id, visible]);
  useEffect(() => {
    if (followMessages.current) scroll.current?.scrollTo({ top: scroll.current.scrollHeight, behavior: "auto" });
  }, [messages, pending, streamed, visible, current.id]);
  function scrollToLatest() {
    followMessages.current = true; setAwayFromBottom(false);
    scroll.current?.scrollTo({ top: scroll.current.scrollHeight, behavior: reduceMotion ? "auto" : "smooth" });
  }
  async function switchSession(session?: ChatSession) {
    if (captureLock.current || mutation.current || deleteTarget || rename!==null || !historyReady || session?.id === currentRef.current.id) return;
    mutation.current = true; setSwitching(true);
    try {
      if (await persist(currentRef.current)) {
        setConversationRevision((value) => value + 1);
        replaceCurrent(session ? sessionsRef.current.find(entry => entry.id === session.id) ?? session : newChatSession(selection)); setNotice(""); setRename(null);
        if (!session) setFilter("");
      }
    } finally { mutation.current = false; setSwitching(false); }
  }
  useEffect(() => {
    if (!visible || closing) return;
    const onKey = (event: KeyboardEvent) => {
      if (isCompositionKey(event) || composing.current || event.defaultPrevented) return;
      if (captureLock.current) return;
      if (event.key === "Escape") {
        event.preventDefault();
        if (event.repeat) return;
        if (deleteTarget) { if (!mutation.current) setDeleteTarget(null); return; }
        if(rename!==null){if(!mutation.current)setRename(null);return;}
        void persist(currentRef.current); onClose();
      } else if ((event.metaKey || event.ctrlKey) && !event.altKey && !event.shiftKey) {
        if (event.target instanceof Element && event.target.closest('[role="dialog"]')) return;
        if (/^[1-9]$/.test(event.key)) {
          event.preventDefault();
          if (!event.repeat && history[Number(event.key) - 1]) void switchSession(history[Number(event.key) - 1]);
        } else if (event.key.toLowerCase() === "n") {
          event.preventDefault(); if (!event.repeat) void switchSession();
        }
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  async function cancelRequest(sessionId: string) {
    const request = requests.current.get(sessionId);
    if (!request?.id || !request.pending || request.cancelled) return;
    const id = request.id;
    patchRequest(sessionId, { cancelled: true });
    try { await invoke("ai_cancel", { requestId: id }); }
    catch (error) {
      if (requests.current.get(sessionId)?.id === id) patchRequest(sessionId, { cancelled: false, error: aiErrorText(error) });
    }
  }
  async function send(override?: ChatSession) {
    const source = override ?? currentRef.current;
    if (isRunning(source.id) || mutation.current || !source.draft.trim() || !readyToSend || filesBusy || rename !== null) return;
    if ([...requests.current.values()].filter(request => request.id).length >= MAX_CONCURRENT_REQUESTS) {
      setError(t("Up to three conversations can reply at once. Wait for a reply or stop one.")); return;
    }
    const session = { ...source, title: ![t("새 대화"), t("New conversation")].includes(source.title) ? source.title : source.draft.trim().replace(/\s+/g, " ").slice(0, 70), updatedAt: Date.now() };
    const question = session.draft.trim();
    const turns: ChatMessage[] = [...session.messages, { role: "user", content: question, ...(session.draftImage ? {image: session.draftImage} : {}) }];
    if (turns.filter(turn => turn.image).length > 4) { setError(t("A conversation can contain up to four screen captures. Start a new conversation.")); return; }
    if (turns.length > 40 || new TextEncoder().encode(question).length > 32_000 || turns.reduce((size, message) => size + new TextEncoder().encode(message.content).length, 0) > 128_000) {
      setError(t("대화가 너무 깁니다. 새 대화를 시작하거나 내용을 줄여 주세요.")); return;
    }
    const id = crypto.randomUUID();
    const ownsRequest = () => alive.current && !deleting.current.has(session.id) && requests.current.get(session.id)?.id === id;
    patchRequest(session.id, { ...idleRequest, id, question });
    followMessages.current = true; setAwayFromBottom(false); setNotice(""); replaceCurrent(session);
    try {
      // Save the unanswered question before inference. Switching never changes this request's owner.
      if (!await persist(session) || !ownsRequest()) return;
      patchRequest(session.id, { pending: question });
      const onEvent = new Channel<{ text: string }>();
      onEvent.onmessage = event => {
        if (ownsRequest() && !requests.current.get(session.id)?.cancelled && typeof event.text === "string") patchRequest(session.id, { streamed: event.text });
      };
      const content = await invoke<string>("ai_chat", { onEvent, requestId: id, provider: session.provider, model: session.model, messages: turns, useWeb: session.provider !== "compatible" && useWeb, useFiles });
      if (!ownsRequest()) return;
      if (requests.current.get(session.id)?.cancelled) {
        patchRequest(session.id, { error: t("요청을 중지했습니다. 제공업체에서 이미 처리한 사용량은 청구될 수 있습니다.") }); return;
      }
      const completed: ChatSession = { ...session, draft: "", draftImage: undefined, messages: [...turns, { role: "assistant", content, modelName: session.modelName || session.model }], updatedAt: Date.now() };
      remember(completed);
      if (currentRef.current.id === session.id) replaceCurrent(completed);
      patchRequest(session.id, { streamed: "", question: "", pending: "" });
      await persist(completed);
    } catch (error) { if (ownsRequest()) patchRequest(session.id, { error: aiErrorText(error) }); }
    finally { if (ownsRequest()) patchRequest(session.id, { id: null, pending: "" }); }
  }
  async function changeConversationModel(next: AiSelection) {
    if (captureLock.current || isRunning() || mutation.current || deleteTarget) return;
    mutation.current = true; setSwitching(true);
    const session = { ...currentRef.current, ...next, messages: currentRef.current.messages.map(message => message.role === "assistant" && !message.modelName ? {...message, modelName: currentRef.current.modelName || currentRef.current.model} : message), updatedAt: Date.now() };
    try {
      // Persist the conversation selection before acknowledging it in the composer.
      await queueHistoryOperation(() => saveChatSession(session));
      savedVersions.current.set(session.id, JSON.stringify(session));
      remember(session); replaceCurrent(session); setError("");
    } finally {mutation.current = false; setSwitching(false);}
  }
  function confirmRemoval(session: ChatSession) {
    if (captureLock.current || isRunning(session.id) || mutation.current) return;
    setDeleteError(""); setDeleteTarget(session);
  }
  async function removeSession() {
    if (mutation.current || !deleteTarget || isRunning(deleteTarget.id)) return;
    const id = deleteTarget.id;
    mutation.current = true; setSwitching(true); setDeleteError("");
    deleting.current.add(id);
    try {
      const task = queueHistoryOperation(() => nativeRuntime ? deleteChatSession(id) : undefined);
      await task;
      const previous = sessionsRef.current;
      const index = previous.findIndex((session) => session.id === id);
      const next = previous.filter((session) => session.id !== id);
      sessionsRef.current = next; setSessions(next);
      savedVersions.current.delete(id); versions.current.delete(id); requests.current.delete(id);
      if (currentRef.current.id === id) {
        setConversationRevision((value) => value + 1);
        replaceCurrent(next[Math.max(0, Math.min(index, next.length - 1))] ?? newChatSession(selection));
        setHistoryError(""); setNotice("");setRename(null);
      }
      setDeleteTarget(null);
    } catch (error) { deleting.current.delete(id); setDeleteError(aiErrorText(error)); }
    finally { mutation.current = false; setSwitching(false); }
  }
  async function changeMetadata(update:Partial<Pick<ChatSession,"title"|"pinned">>){
    if(isRunning()||mutation.current)return;mutation.current=true;setSwitching(true);
    const session={...currentRef.current,...update,updatedAt:Date.now()};
    try{
      if(nativeRuntime){const task=queueHistoryOperation(()=>saveChatSession(session));await task;savedVersions.current.set(session.id,JSON.stringify(session));}
      remember(session);replaceCurrent(session);setRename(null);setHistoryError("");
    }catch(error){setHistoryError(aiErrorText(error));}finally{mutation.current=false;setSwitching(false);}
  }
  async function forkMessage(index:number,regenerate=false){
    if(isRunning()||mutation.current||deleteTarget)return;mutation.current=true;setSwitching(true);
    let fork:ChatSession|undefined;
    try{if(await persist(currentRef.current)){fork=forkChatSession(currentRef.current,index);if(await persist(fork)){replaceCurrent(fork);setConversationRevision(v=>v+1);setError("");setFilter("");}else fork=undefined;}}
    finally{mutation.current=false;setSwitching(false);}
    if(fork&&regenerate)void send(fork);
  }
  function openLink(url: string) {
    if (!/^https?:\/\//i.test(url)) return;
    if (nativeRuntime) void invoke("open_web_url", { url }).catch(() => setError(t("링크를 열지 못했습니다.")));
    else window.open(url, "_blank", "noopener,noreferrer");
  }
  async function captureRegion() {
    if (!nativeRuntime || captureLock.current || isRunning() || mutation.current) return;
    const session = currentRef.current;
    if (session.messages.filter(message => message.image).length >= 4) { setError(t("A conversation can contain up to four screen captures. Start a new conversation.")); return; }
    captureLock.current = true; setCapturing(true); setError("");
    try {
      const image = await invoke<ChatImage | null>("ai_capture_region");
      if (image && alive.current && currentRef.current.id === session.id) replaceCurrent({ ...currentRef.current, draftImage: image, updatedAt: Date.now() });
    } catch (error) { if (alive.current) setError(aiErrorText(error)); }
    finally { captureLock.current = false; if (alive.current) { setCapturing(false); composer.current?.focus(); } }
  }
  if (!visible) return null;
  async function toggleFiles() {
    if (busy || filesLock.current || !nativeRuntime) return;
    if (useFiles) { setUseFiles(false); return; }
    filesLock.current = true; setFilesBusy(true); setError("");
    try {
      let next = await getAiTools();
      if (!next.folders.length) next = await invoke("ai_add_folder",{locale:currentLocale()});
      else if (!next.localFiles) next = await setAiTools({...next, localFiles:true});
      setToolSettings(next);
      setUseFiles(next.localFiles && next.folders.length > 0);
      notifyAiSettingsChanged();
    } catch (e) { setError(aiErrorText(e)); }
    finally { filesLock.current = false; setFilesBusy(false); }
  }
  const displayMessages: ChatMessage[] = pending || streamed ? [...messages, {role:"user",content:pending||streamQuestion,image:current.draftImage}, ...(streamed?[{role:"assistant" as const,content:streamed,modelName:current.modelName}]:[])] : messages;
  const conversation = <>
      <header className="ai-header"><div data-tauri-drag-region><strong>{!hasSavedSession&&!messages.length&&!draft?t("New conversation"):current.title}</strong><span className="ai-model-label">{current.modelName || model || t("모델을 선택하세요")} · {providerName}</span></div><button className="ai-icon-button" aria-label={t("대화 이름 변경")} title={t("이름 변경")} disabled={busy||switching} onClick={()=>setRename(current.title)}><Pencil size={14}/></button><button className="ai-icon-button" aria-label={current.pinned?t("대화 고정 해제"):t("대화 고정")} title={current.pinned?t("고정 해제"):t("고정")} aria-pressed={!!current.pinned} disabled={busy||switching} onClick={()=>void changeMetadata({pinned:!current.pinned})}><Pin size={14}/></button><button className="ai-icon-button" aria-label={t("대화 내보내기")} title={t("Markdown 내보내기")} disabled={busy} onClick={()=>{if(nativeRuntime)void invoke<boolean>("ai_export_session",{session:currentRef.current,locale:currentLocale()}).then(saved=>{if(saved)setNotice(t("대화를 내보냈습니다."));}).catch(error=>setNotice(aiErrorText(error)));else downloadChat(currentRef.current);}}><Download size={14}/></button><button className="ai-icon-button" aria-label={t("현재 대화 삭제")} title={busy ? t("Stop this reply before deleting the conversation.") : t("대화 삭제")} onClick={() => confirmRemoval(currentRef.current)} disabled={busy || switching || (!hasSavedSession && !draft && !current.draftImage && !messages.length)}><Trash2 size={15} /></button></header>
      {rename!==null&&<form className="ai-rename" onSubmit={event=>{event.preventDefault();if(rename.trim())void changeMetadata({title:rename.trim()});}}><input aria-label={t("대화 이름")} autoFocus value={rename} maxLength={70} disabled={switching} onChange={e=>setRename(e.target.value)}/><button disabled={switching||!rename.trim()}>{t("저장")}</button><button type="button" disabled={switching} onClick={()=>setRename(null)}>{t("취소")}</button></form>}
      <div className="ai-messages" ref={(element) => { if (currentRef.current.id === current.id) scroll.current = element; }} onScroll={(event) => {
        if (currentRef.current.id !== current.id) return;
        const element = event.currentTarget;
        const away = element.scrollHeight - element.scrollTop - element.clientHeight > 80;
        followMessages.current = !away; setAwayFromBottom(away);
      }} role="log" aria-label={t("대화")} aria-live="polite">
        {displayMessages.length === 0 ? <div className="ai-welcome"><div className="ai-welcome-mark"><Sparkles size={26} /></div><h2>{t("무엇을 함께 해볼까요?")}</h2><p>{readyToSend ? t("질문하거나 텍스트를 붙여넣어 보세요.") : checking ? t("저장된 AI 연결을 확인하고 있습니다…") : t("API 키와 모델을 연결하면 바로 대화할 수 있습니다.")}</p>
          {readyToSend ? <div className="ai-presets">{presets.map((preset) => <button key={preset.label} onClick={() => { updateDraft(preset.prompt); composer.current?.focus(); }}>{preset.label}</button>)}</div> : <button className="ai-connect-button" onClick={onOpenSettings}>{t("AI 설정 열기")}</button>}
          {!nativeRuntime && <p className="ai-preview-note">{t("브라우저 미리보기입니다. AI 연결은 macOS 앱에서 사용할 수 있습니다.")}</p>}
        </div> : displayMessages.map((message, index) => <motion.article className={`ai-message ${message.role}`} key={`${index}-${message.role}`} initial={reduceMotion ? false : { opacity: 0, y: 7 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.24, ease: [0.22, 1, 0.36, 1] }}>
          <div className="ai-message-label"><strong>{message.role === "user" ? t("나") : message.modelName || current.modelName || model}</strong><button className="ai-icon-button" aria-label={message.role === "user" ? t("질문 복사") : t("답변 복사")} onClick={() => { void navigator.clipboard.writeText(message.content).then(() => setNotice(t("복사했습니다."))).catch(() => setNotice(t("복사하지 못했습니다."))); }}><Copy size={13} /></button>{index<messages.length&&<button className="ai-icon-button" disabled={busy||switching} aria-label={message.role==="user"?t("질문 수정"):t("답변 다시 생성")} title={message.role==="user"?t("질문을 수정해 새 대화로 이어가기"):t("원본을 유지하고 다시 생성")} onClick={()=>void forkMessage(message.role==="user"?index:index-1,message.role==="assistant")}>{message.role==="user"?<Pencil size={13}/>:<RotateCcw size={13}/>}</button>}</div>
          {message.image && <img className="ai-capture-preview" src={message.image.dataUrl} alt={t("Screen capture")} />}
          <div className={`ai-message-content${message.role === "assistant" ? " ai-markdown" : ""}`}>{message.role === "user" ? message.content : <Markdown remarkPlugins={[remarkGfm]} skipHtml components={{ pre: ({children})=><div className="ai-code-block"><button type="button" aria-label={t("코드 복사")} onClick={event=>{const code=event.currentTarget.parentElement?.querySelector("code")?.textContent??"";void navigator.clipboard.writeText(code).then(()=>setNotice(t("코드를 복사했습니다."))).catch(()=>setNotice(t("복사하지 못했습니다.")));}}><Copy size={13}/></button><pre>{children}</pre></div>, img: ({ alt }) => <span>{alt ? t("[이미지: {0}]", {"0": alt}) : t("[이미지]")}</span>, a: ({ href, children }) => <a href={href} onClick={(event) => { event.preventDefault(); if (href) openLink(href); }}>{children}</a> }}>{message.content}</Markdown>}</div>
        </motion.article>)}
        {streamed&&!busy&&<p className="ai-partial-note">{t("중단된 답변 · 아래 질문을 다시 보내 이어갈 수 있습니다.")}</p>}
        {busy && !streamed && <p className="ai-thinking" role="status"><span />{pending ? useWeb || useFiles ? t("필요한 자료를 확인하고 답변을 작성하고 있습니다…") : t("답변을 작성하고 있습니다…") : t("질문을 저장하고 있습니다…")}</p>}
      </div>
      {awayFromBottom && <button className="ai-jump-latest" aria-label={t("최신 메시지로 이동")} onClick={scrollToLatest}><ArrowDown size={14} /> {t("최신 메시지")}</button>}
      {error && <div className="ai-request-error ai-feedback-enter" role="alert"><p>{error.split("\n")[0]}</p>{error.includes("\n") && <details><summary>{t("오류 정보")}</summary><pre>{error.split("\n").slice(1).join("\n")}</pre></details>}<div><button onClick={() => void send()} disabled={busy || !draft.trim() || !readyToSend}>{t("다시 보내기")}</button><button onClick={onOpenSettings} disabled={busy}>{t("모델·연결 설정")}</button></div></div>}
      {failedEntry && <div className="ai-notice" role="status">{t("Your new draft is waiting until the current conversation can be saved.")} <button disabled={switching} onClick={() => void acceptEntry(failedEntry)}>{t("Open new draft")}</button></div>}
      {historyError && <div className="ai-notice ai-error" role="alert">{t(historyError)} <button onClick={() => { if (historyReady) void persist(currentRef.current); else setHistoryRevision((value) => value + 1); }}>{t("기록 저장·조회 다시 시도")}</button></div>}
      {messages.length > 0 && !configured && !checking && <div className="ai-session-model-note">{t("계속 대화하려면 이 제공업체의 API 키를 연결하세요.")}<button onClick={onOpenSettings}>{t("AI 설정 열기")}</button></div>}
      {((provider !== "compatible" && useWeb) || useFiles) && <div className="ai-context-hint">{provider !== "compatible" && useWeb && <span><Globe size={12}/> {t("웹 검색")}{provider === "openai" ? "· OpenAI" : "· Perplexity Sonar"}</span>}{useFiles && <span><FolderOpen size={12}/> {toolSettings.folders.length===1?t("1 permitted folder · Read content is sent to AI"):t("{0} permitted folders · Read content is sent to AI",{0:toolSettings.folders.length})}</span>}</div>}
      <form className="ai-composer" onSubmit={(event) => { event.preventDefault(); void send(); }}>
        {current.draftImage && !busy && <div className="ai-capture-attachment"><img className="ai-capture-preview" src={current.draftImage.dataUrl} alt={t("Attached screen capture")} /><div><span>{t("Screen capture")}</span><small>{t("Sent with your question · Choose a model that supports images")}</small></div><button type="button" className="ai-icon-button" aria-label={t("Remove screen capture")} disabled={capturing || switching} onClick={() => replaceCurrent({...currentRef.current, draftImage: undefined, updatedAt: Date.now()})}><X size={14}/></button></div>}
        <textarea ref={(element) => { if (currentRef.current.id === current.id) composer.current = element; }} aria-label={t("AI 메시지")} placeholder={t("질문을 입력하세요…")} value={busy ? "" : draft} disabled={busy || capturing || !historyReady || switching} maxLength={32000} rows={2}
          onChange={(event) => updateDraft(event.target.value)} onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }}
          onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey && !event.metaKey && !event.ctrlKey && !event.altKey && !isCompositionKey(event.nativeEvent) && !composing.current) { event.preventDefault(); if (!event.repeat) void send(); } }} />
        <div className="ai-composer-bottom"><div className="ai-composer-controls"><AiModelPicker selection={current} disabled={busy || !historyReady} nativeRuntime={nativeRuntime} onSelect={changeConversationModel} onSettings={onOpenSettings}/><button type="button" className="ai-icon-button" aria-label={t("Capture screen region")} title={t("Capture screen region")} disabled={!nativeRuntime || busy || capturing || switching || !historyReady} onClick={() => void captureRegion()}><Scan size={16}/></button><button type="button" className="ai-tool-chip" aria-label={t("이 질문에 웹 검색 사용")} aria-pressed={provider !== "compatible" && useWeb} disabled={busy || provider === "compatible" || !toolSettings.webSearch} title={provider === "compatible" ? t("Web search is not available for custom API servers.") : toolSettings.webSearch ? t("필요할 때 웹 검색 · 추가 요금") : t("AI 설정에서 웹 검색을 허용하세요")} onClick={()=>setUseWeb(v=>!v)}><Globe size={14}/><span>{t("웹")}</span></button><button type="button" className="ai-tool-chip" aria-label={t("이 질문에 로컬 파일 사용")} aria-pressed={useFiles} disabled={busy || filesBusy || !nativeRuntime} title={toolSettings.localFiles ? t("허용 폴더의 텍스트를 AI에 전달") : t("AI가 읽을 폴더 선택")} onClick={()=>void toggleFiles()}><FolderOpen size={14}/><span>{t("파일")}</span></button><button type="button" className="ai-icon-button" aria-label={t("AI 도구 설정")} onClick={onOpenSettings} disabled={busy}><SlidersHorizontal size={14}/></button></div>{busy ? <button type="button" className="ai-send" aria-label={t("응답 중지")} onClick={() => void cancelRequest(current.id)} disabled={!pending || activeRequest.cancelled}><Square size={13} /><span>{t("중지")}</span></button> : <button className="ai-send" type="submit" disabled={!draft.trim() || !readyToSend || filesBusy || activeCount >= MAX_CONCURRENT_REQUESTS} title={activeCount >= MAX_CONCURRENT_REQUESTS ? t("Up to three conversations can reply at once. Wait for a reply or stop one.") : undefined} aria-label={t("메시지 전송")}><span>{t("보내기")}</span><ArrowUp size={16} /></button>}</div>
      </form>
      {notice && <div className="ai-notice" role="status">{t(notice)}</div>}

  </>;
  return <section className="ai-chat" aria-label={t("AI Chat")} inert={closing} data-reduced-motion={reduceMotion || undefined}>
    <aside className="ai-session-sidebar" aria-label={t("대화 기록")} inert={!!deleteTarget}>
      <div className="ai-sidebar-heading"><button className="ai-icon-button" onClick={() => { void persist(currentRef.current); onClose(); }} aria-label={t("Back to commands")} title={t("검색으로 돌아가기")}><ArrowLeft size={17} /></button><strong>{t("AI Chat")}</strong><Sparkles size={15} /></div>
      <button className="ai-new-session" onClick={() => void switchSession()} disabled={switching || !historyReady} aria-label={t("새 대화")} aria-keyshortcuts="Meta+N Control+N"><Plus size={15} /> {t("새 대화")}</button>
      <label className="ai-history-search"><Search size={13} /><input type="search" aria-label={t("대화 검색")} placeholder={t("대화 검색")} value={filter} onChange={(event) => setFilter(event.target.value)} /></label>
      <nav className="ai-session-list" aria-label={t("저장된 대화")}>
        {history.map((session, index) => <div className="ai-session-row" key={session.id}><button className={`ai-session${session.id === current.id ? " active" : ""}`} aria-current={session.id === current.id ? "page" : undefined} aria-keyshortcuts={index < 9 ? `Meta+${index + 1} Control+${index + 1}` : undefined} disabled={switching} onClick={() => void switchSession(session)}>
          {session.pinned?<Pin size={14}/>:<MessageSquare size={14} />}<span><strong>{["새 대화","New conversation"].includes(session.title) && session.draft ? session.draft.trim().slice(0, 45) : session.title}</strong><small>{isRunning(session.id) ? t("답변을 작성하고 있습니다…") : session.modelName || session.model || aiProviders[session.provider].name}</small></span>
        </button><button className="ai-icon-button ai-session-delete" aria-label={t("{0} 대화 삭제", {"0": session.title})} title={isRunning(session.id) ? t("Stop this reply before deleting the conversation.") : t("대화 삭제")} disabled={isRunning(session.id) || switching} onClick={() => confirmRemoval(session)}><Trash2 size={13} /></button></div>)}
        {!history.length && <p className="ai-history-empty">{filter ? t("검색 결과가 없습니다.") : historyReady ? t("대화를 시작하면 여기에 쌓입니다.") : t("대화 기록을 불러오는 중…")}</p>}
      </nav>
      <div className="ai-history-footer"><button onClick={onOpenSettings} disabled={busy} aria-label={t("AI 연결 설정")}><KeyRound size={14} /> {t("AI 설정")}</button></div>
    </aside>
    <div className="ai-conversation-stage" inert={!!deleteTarget}>
      {reduceMotion ? <div className="ai-conversation">{conversation}</div> : <AnimatePresence initial={false}>
        <AiConversationTransition key={conversationRevision} onReady={() => {
          if (currentRef.current.id === current.id && visible && !busy && historyReady && !closing && document.activeElement === document.body) composer.current?.focus();
        }}>{conversation}</AiConversationTransition>
      </AnimatePresence>}
    </div>
    {deleteTarget && <div className="ai-delete-overlay"><section className="ai-delete-dialog" role="alertdialog" aria-modal="true" aria-labelledby="ai-delete-title" aria-describedby="ai-delete-description" onKeyDown={(event) => {
      if (event.key !== "Tab") return;
      event.preventDefault();
      const controls = [...event.currentTarget.querySelectorAll<HTMLButtonElement>("button:not(:disabled)")];
      const index = controls.indexOf(document.activeElement as HTMLButtonElement);
      controls[(index + (event.shiftKey ? -1 : 1) + controls.length) % controls.length]?.focus();
    }}>
      <h2 id="ai-delete-title">{t("대화를 삭제할까요?")}</h2><p id="ai-delete-description">{t("Delete all messages and drafts in “{0}”?",{0:deleteTarget.title})}</p>
      {deleteError && <p className="ai-error" role="alert">{deleteError}</p>}
      <div><button ref={cancelDeleteButton} onClick={() => setDeleteTarget(null)} disabled={switching}>{t("취소")}</button><button className="ai-delete-submit" onClick={() => void removeSession()} disabled={switching}>{switching ? t("삭제 중…") : deleteError ? t("삭제 다시 시도") : t("삭제")}</button></div>
    </section></div>}
  </section>;
}

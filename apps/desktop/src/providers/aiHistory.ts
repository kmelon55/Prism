import { t } from "../i18n";
import { invoke } from "@tauri-apps/api/core";
import type { AiSelection } from "./ai";
export interface ChatImage { dataUrl: string }
export interface ChatMessage { role: "user" | "assistant"; content: string; modelName?: string | null; image?: ChatImage }
export interface ChatSession extends AiSelection {
  id: string;
  title: string;
  messages: ChatMessage[];
  draft: string;
  draftImage?: ChatImage;
  updatedAt: number;
  pinned?: boolean;
}
export const newChatSession = (selection: AiSelection, draft = ""): ChatSession => ({ ...selection, id: crypto.randomUUID(), title: t("새 대화"), messages: [], draft, updatedAt: Date.now() });
export const loadChatHistory = () => invoke<ChatSession[]>("ai_load_history");
export const saveChatSession = (session: ChatSession) => invoke<ChatSession>("ai_save_session", { session });
export const deleteChatSession = (sessionId: string) => invoke<void>("ai_delete_session", { sessionId });

export function sortChatSessions(sessions: ChatSession[]): ChatSession[] {
  return [...sessions].sort((a,b)=>Number(!!b.pinned)-Number(!!a.pinned)||b.updatedAt-a.updatedAt);
}
export function forkChatSession(session:ChatSession,userIndex:number):ChatSession {
  if(userIndex<0||session.messages[userIndex]?.role!=="user")throw new Error(t("Choose a user message to edit."));
  return {...session,id:crypto.randomUUID(),title:`${session.title.slice(0,58)} · ${t("Rewrite")}`,pinned:false,messages:session.messages.slice(0,userIndex),draft:session.messages[userIndex].content,draftImage:session.messages[userIndex].image,updatedAt:Date.now()};
}
export function chatMarkdown(session:ChatSession):string {
  return `# ${session.title.replace(/[\r\n]+/g," ")}\n\n`+session.messages.map(message=>`## ${message.role==="user"?t("나"):message.modelName||session.modelName||session.model}\n\n${message.image ? `![Screen capture](${message.image.dataUrl})\n\n` : ""}${message.content}\n`).join("\n")+(session.draftImage?`\n![Draft screen capture](${session.draftImage.dataUrl})\n`:"")+(session.draft?`\n## ${t("Draft")}\n\n${session.draft}\n`:"");
}
export function downloadChat(session:ChatSession){
  const url=URL.createObjectURL(new Blob([chatMarkdown(session)],{type:"text/markdown;charset=utf-8"}));
  const anchor=document.createElement("a");anchor.href=url;anchor.download=`${session.title.replace(/[\/:*?"<>|\x00-\x1f]/g,"_").slice(0,70)||t("대화")}.md`;anchor.click();window.setTimeout(()=>URL.revokeObjectURL(url),1000);
}

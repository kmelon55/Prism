import { invoke } from "@tauri-apps/api/core";
export interface AiToolSettings { localFiles: boolean; maxOutputTokens: number; folders: { id: string; path: string }[] }
export const defaultAiTools: AiToolSettings = { localFiles: false, maxOutputTokens: 16384, folders: [] };
export const getAiTools = () => invoke<AiToolSettings>("ai_get_tools");
export const setAiTools = ({localFiles, maxOutputTokens}: AiToolSettings) => invoke<AiToolSettings>("ai_set_tools", { localFiles, maxOutputTokens });

import { invoke } from "@tauri-apps/api/core";
export interface AiToolSettings { webSearch: boolean; localFiles: boolean; maxOutputTokens: number; folders: { id: string; path: string }[] }
export const defaultAiTools: AiToolSettings = { webSearch: false, localFiles: false, maxOutputTokens: 16384, folders: [] };
export const getAiTools = () => invoke<AiToolSettings>("ai_get_tools");
export const setAiTools = ({webSearch, localFiles, maxOutputTokens}: AiToolSettings) => invoke<AiToolSettings>("ai_set_tools", { webSearch, localFiles, maxOutputTokens });

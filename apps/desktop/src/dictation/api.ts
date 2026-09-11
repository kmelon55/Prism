import { cleanupInstruction, promptInstruction, type EnhancementMode } from "./processing";
import type { AiSelection } from "../providers/ai";
import { recordingDefaults, type RecordingBinding } from "./recordingShortcuts";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
export type DictationProvider = "local" | "openai" | "vercel" | "groq" | "xai" | "custom";
export interface DictationSettings {
  enhancementMode: EnhancementMode;
  cleanupModel: AiSelection | null;
  promptModel: AiSelection | null;
  cleanupInstruction: string;
  promptInstruction: string;
  refineText: boolean;
  processingModel: AiSelection | null;
  defaultDelivery: "copy" | "paste";
  recordingCancelShortcut: RecordingBinding;
  recordingCopyShortcut: RecordingBinding;
  recordingPasteShortcut: RecordingBinding;
  recordingPasteAndEnterShortcut: RecordingBinding;
  provider: DictationProvider; model: string; baseURL: string; language: string;
  prompt: string; vocabulary: string[]; whisperPath: string; modelPath: string; uiLanguage: "ko" | "en"; showRecordingShortcutHints: boolean; showTranscriptionStatus: boolean;
}
export interface DictationStatus {
  phase: "idle" | "preparing" | "recording" | "transcribing" | "processing" | "inserting" | "success" | "error" | "preview";
  shortcutWarning?: string;
  hasOriginal?: boolean;
  message: string; microphone: "granted" | "notDetermined" | "denied" | "restricted";
  accessibility: boolean; hasTranscript: boolean;
}
export const providers: { id: DictationProvider; name: string; baseURL: string }[] = [
  { id: "local", name: "Local · whisper.cpp", baseURL: "" },
  { id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1" },
  { id: "vercel", name: "Vercel AI Gateway", baseURL: "https://ai-gateway.vercel.sh/v4/ai" },
  { id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1" },
  { id: "xai", name: "xAI", baseURL: "https://api.x.ai/v1" },
  { id: "custom", name: "OpenAI-compatible", baseURL: "" },
];
export const defaultSettings: DictationSettings = { ...recordingDefaults, enhancementMode: "off", cleanupModel: null, promptModel: null, cleanupInstruction, promptInstruction, refineText: false, processingModel: null, defaultDelivery: "paste", provider: "local", model: "", baseURL: "", language: "auto", prompt: "", vocabulary: [], whisperPath: "/opt/homebrew/bin/whisper-cli", modelPath: "", uiLanguage: "ko", showRecordingShortcutHints: true, showTranscriptionStatus: true };
export function changeProvider(settings: DictationSettings, provider: DictationProvider): DictationSettings {
  const entry = providers.find(entry => entry.id === provider)!;
  return { ...settings, provider, model: provider === "xai" ? "grok-stt" : "", baseURL: entry.baseURL };
}
export const getDictationSettings = () => invoke<DictationSettings>("dictation_get_settings");
export const saveDictationSettings = (settings: DictationSettings) => invoke<DictationSettings>("dictation_save_settings", { settings });
export const dictationAction = (action: "status" | "cancel" | "preview" | "copy" | "copyOriginal" | "microphoneSettings" | "microphoneRequest", previewSettings?: DictationSettings) => invoke<DictationStatus>("dictation_action", { action, ...(previewSettings ? { previewSettings } : {}) });
export const toggleDictation = () => invoke<void>("dictation_toggle");
export const watchDictation = (callback: (status: DictationStatus) => void) => listen<DictationStatus>("prism:dictation-state", event => callback(event.payload));

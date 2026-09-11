import type { DictationSettings } from "./api";
export type EnhancementMode = "off" | "cleanup" | "prompt";
export const cleanupInstruction = "Correct punctuation, spelling and spacing. Remove redundant repetitions and fillers. Preserve the speaker's meaning and tone without summarizing or adding information.";
export const promptInstruction = "Rewrite as a clear prompt for another AI. Organize the stated goal, context, constraints and requested output. Do not add requirements or details that the speaker did not state. Do not answer the prompt.";
export function upgradeProcessing(settings: DictationSettings): DictationSettings {
  const legacy = settings.enhancementMode == null;
  return { ...settings,
    enhancementMode: settings.enhancementMode ?? (settings.refineText ? "cleanup" : settings.processingModel ? "prompt" : "off"),
    cleanupModel: settings.cleanupModel ?? (legacy ? settings.processingModel : null),
    promptModel: settings.promptModel ?? (legacy ? settings.processingModel : null),
    cleanupInstruction: settings.cleanupInstruction ?? cleanupInstruction,
    promptInstruction: settings.promptInstruction ?? promptInstruction,
  };
}

import type { CommandItem, CommandProvider } from "@prism/command-core";

const commands: CommandItem[] = [
  {
    id: "demo:focus",
    providerId: "demo",
    title: "Start a focus session",
    subtitle: "25 minutes · notifications stay untouched",
    section: "Prism commands",
    kind: "command",
    keywords: ["timer", "pomodoro", "deep work"],
    icon: "focus",
    accent: "violet",
    detail: {
      eyebrow: "Local command",
      title: "Focus, with less ceremony",
      description:
        "Starts a lightweight local timer. This MVP keeps notification permissions out of the critical path.",
      metadata: [
        { label: "Duration", value: "25 minutes" },
        { label: "Provider", value: "Demo provider" },
        { label: "Network", value: "Not required" },
      ],
    },
    actions: [
      { id: "start-focus", title: "Start focus session", shortcut: ["↵"], style: "accent" },
      { id: "copy-title", title: "Copy command name", shortcut: ["⌘", "C"] },
    ],
  },
  {
    id: "demo:clipboard",
    providerId: "demo",
    title: "Copy workspace path",
    subtitle: "/Users/kimgyeongmo/Documents/Prism",
    section: "Developer tools",
    kind: "command",
    keywords: ["path", "project", "folder"],
    icon: "copy",
    accent: "cyan",
    detail: {
      eyebrow: "Developer tool",
      title: "Prism workspace",
      description: "Copies the current project path without invoking a shell command.",
      metadata: [
        { label: "Action", value: "Clipboard write" },
        { label: "Side effects", value: "Clipboard only" },
      ],
    },
    actions: [
      { id: "copy-workspace", title: "Copy path", shortcut: ["↵"], style: "accent" },
      { id: "copy-title", title: "Copy command name", shortcut: ["⌘", "C"] },
    ],
  },
  {
    id: "demo:error",
    providerId: "demo",
    title: "Preview provider recovery",
    subtitle: "Developer-only error state",
    section: "Developer tools",
    kind: "command",
    keywords: ["error", "failure", "resilience"],
    icon: "triangle-alert",
    accent: "rose",
    detail: {
      eyebrow: "Resilience check",
      title: "One provider should not take down search",
      description:
        "Runs the deliberate !error query. Prism will report the failing provider while keeping the shell usable.",
      metadata: [
        { label: "Scope", value: "Demo provider only" },
        { label: "Recovery", value: "Clear the query" },
      ],
    },
    actions: [{ id: "trigger-error", title: "Show error state", shortcut: ["↵"], style: "accent" }],
  },
];

export const demoProvider: CommandProvider = {
  id: "demo",
  label: "Demo commands",
  async search(_query, signal) {
    if (signal.aborted) return [];
    return commands;
  },
};

export const resilienceProvider: CommandProvider = {
  id: "resilience-demo",
  label: "Recovery demo",
  async search(query, signal) {
    if (signal.aborted) return [];
    if (query.trim() === "!error") {
      throw new Error("Deliberate provider failure — the rest of Prism is still available.");
    }
    return [];
  },
};

import { useEffect, useLayoutEffect, useRef } from "react";
import type { CommandAction, CommandItem } from "@prism/command-core";
import { clampIndex, escapeAction, type PaletteView } from "./navigation";

interface KeyboardContext {
  query: string;
  view: PaletteView;
  settings: boolean;
  recording: boolean;
  selectedItem?: CommandItem;
  actionItem?: CommandItem;
  actionIndex: number;
  itemCount: number;
  input: React.RefObject<HTMLInputElement | null>;
  cancelRecording(): void;
  clearQuery(): void;
  goBack(): void;
  hide(): void;
  openSettings(): void;
  openAiChat?(): void;
  openActions(): void;
  closeActions(): void;
  moveSelection(direction: number): void;
  selectAction(index: number): void;
  execute(action: CommandAction, item: CommandItem): void;
  cycleTheme(): void;
}

/** Keep IME keys out of every palette/settings keyboard handler without canceling IME defaults. */
export function isCompositionKey(event: Pick<KeyboardEvent, "isComposing" | "keyCode">): boolean {
  // 229 also covers compositionstart/end arriving on the other side of keydown.
  return event.isComposing || event.keyCode === 229;
}

function matchesShortcut(event: KeyboardEvent, keys: string[] | undefined): boolean {
  if (!keys || keys.length < 2) return false;
  const mac = /Mac|iPhone|iPad/.test(navigator.userAgent);
  const lower = keys.map((key) => key.toLowerCase());
  const primary = lower.includes("⌘") || lower.includes("cmd") || lower.includes("ctrl");
  return event.key.toLowerCase() === lower.at(-1)
    && event.metaKey === (primary && mac)
    && event.ctrlKey === (primary && !mac)
    && event.shiftKey === (lower.includes("shift") || lower.includes("⇧"))
    && event.altKey === (lower.includes("alt") || lower.includes("⌥"));
}

export function usePaletteKeyboard(context: KeyboardContext) {
  const current = useRef(context);
  const composing = useRef(false);
  useLayoutEffect(() => { current.current = context; });

  useEffect(() => {
    const beginComposition = () => { composing.current = true; };
    const endComposition = () => { composing.current = false; };
    const keydown = (event: KeyboardEvent) => {
      if (composing.current || isCompositionKey(event)) {
        event.stopPropagation();
        return;
      }
      if (event.defaultPrevented) return;
      const ctx = current.current;
      const modifier = event.metaKey || event.ctrlKey;
      const consume = () => { event.preventDefault(); event.stopPropagation(); };

      if (event.key === "Escape") {
        const action = escapeAction({
          recording: ctx.recording, settings: ctx.settings, actions: Boolean(ctx.actionItem),
          query: ctx.query, view: ctx.view,
        });
        // Settings owns confirmations and local form inputs, and receives this event itself.
        if (action === "settings") return;
        consume();
        if (event.repeat) return;
        switch (action) {
          case "recorder": ctx.cancelRecording(); break;
          case "actions": ctx.closeActions(); break;
          case "clear": ctx.clearQuery(); break;
          case "back": ctx.goBack(); break;
          case "hide": ctx.hide(); break;
        }
        return;
      }
      if (ctx.recording || ctx.settings) return;
      if (modifier && event.key.toLowerCase() === "w") {
        consume();
        if (!event.repeat) ctx.hide();
        return;
      }
      if (ctx.actionItem) {
        // Text editing in the action search must not copy a command's path instead of selected text.
        const target = event.target;
        if (modifier && target instanceof HTMLInputElement) {
          const key = event.key.toLowerCase();
          if (["a", "v", "z"].includes(key)
            || (["c", "x"].includes(key) && target.selectionStart !== target.selectionEnd)) return;
        }
        if (modifier && event.key.toLowerCase() === "k") {
          consume();
          if (!event.repeat) ctx.closeActions();
          return;
        }
        const shortcutAction = ctx.actionItem.actions.find((action) => matchesShortcut(event, action.shortcut));
        if (shortcutAction) {
          consume();
          if (!event.repeat) ctx.execute(shortcutAction, ctx.actionItem);
          return;
        }
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          consume();
          ctx.selectAction(clampIndex(
            ctx.actionIndex + (event.key === "ArrowDown" ? 1 : -1), ctx.actionItem.actions.length,
          ));
        } else if (event.key === "Enter" && !modifier && !event.altKey) {
          // A focused close button retains normal Enter/Space activation.
          if (event.target instanceof Element && event.target.closest("[data-close-actions]")) return;
          consume();
          const action = ctx.actionItem.actions[ctx.actionIndex];
          if (action && !event.repeat) ctx.execute(action, ctx.actionItem);
        }
        return;
      }
      if (event.key === "Tab" && !modifier && !event.altKey && !event.shiftKey
        && event.target === ctx.input.current && ctx.view === "root" && ctx.openAiChat) {
        consume();
        if (!event.repeat) ctx.openAiChat();
      } else if (modifier && event.key.toLowerCase() === "k" && ctx.selectedItem) {
        consume();
        if (!event.repeat) ctx.openActions();
      } else if (modifier && event.key === ",") {
        consume();
        if (!event.repeat) ctx.openSettings();
      } else if (modifier && event.shiftKey && event.key.toLowerCase() === "t") {
        consume();
        if (!event.repeat) ctx.cycleTheme();
      } else if (event.target === ctx.input.current || event.target === document.body) {
        if (!modifier && !event.altKey && (event.key === "ArrowDown" || event.key === "ArrowUp")) {
          consume();
          if (ctx.itemCount) ctx.moveSelection(event.key === "ArrowDown" ? 1 : -1);
        } else if (event.key === "Enter" && !modifier && !event.altKey) {
          consume();
          const action = ctx.selectedItem?.actions[0];
          if (action && ctx.selectedItem && !event.repeat) ctx.execute(action, ctx.selectedItem);
        }
      }
    };
    window.addEventListener("compositionstart", beginComposition, true);
    window.addEventListener("compositionend", endComposition, true);
    window.addEventListener("blur", endComposition);
    window.addEventListener("keydown", keydown, true);
    return () => {
      window.removeEventListener("compositionstart", beginComposition, true);
      window.removeEventListener("compositionend", endComposition, true);
      window.removeEventListener("blur", endComposition);
      window.removeEventListener("keydown", keydown, true);
    };
  }, []);
}

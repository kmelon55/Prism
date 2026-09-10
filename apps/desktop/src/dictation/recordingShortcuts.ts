// Whisp's Carbon key codes and recording shortcut modes, adapted for Prism's recorder.
export type RecordingMode = "custom" | "disabled" | "sameAsPrimary";
export type RecordingKind = "keyCombination" | "singleControl" | "singleOption" | "singleShift" | "singleCommand";
export interface RecordingBinding { mode: RecordingMode; kind: RecordingKind; keyCode: number; modifiers: number; label: string }
export const recordingDefaults = {
  recordingCopyShortcut: {mode:"disabled",kind:"keyCombination",keyCode:0,modifiers:0,label:""},
  recordingCancelShortcut: {mode:"custom",kind:"keyCombination",keyCode:53,modifiers:0,label:"Esc"},
  recordingPasteShortcut: {mode:"sameAsPrimary",kind:"keyCombination",keyCode:0,modifiers:0,label:""},
  recordingPasteAndEnterShortcut: {mode:"custom",kind:"keyCombination",keyCode:36,modifiers:0,label:"Return"},
} satisfies Record<string, RecordingBinding>;
export type RecordingAction = keyof typeof recordingDefaults;
const codes: Record<string, number> = {KeyA:0,KeyS:1,KeyD:2,KeyF:3,KeyH:4,KeyG:5,KeyZ:6,KeyX:7,KeyC:8,KeyV:9,KeyB:11,KeyQ:12,KeyW:13,KeyE:14,KeyR:15,KeyY:16,KeyT:17,Digit1:18,Digit2:19,Digit3:20,Digit4:21,Digit6:22,Digit5:23,Equal:24,Digit9:25,Digit7:26,Minus:27,Digit8:28,Digit0:29,BracketRight:30,KeyO:31,KeyU:32,BracketLeft:33,KeyI:34,KeyP:35,Enter:36,KeyL:37,KeyJ:38,Quote:39,KeyK:40,Semicolon:41,Backslash:42,Comma:43,Slash:44,KeyN:45,KeyM:46,Period:47,Tab:48,Space:49,Backquote:50,Backspace:51,Escape:53,F17:64,NumpadDecimal:65,NumpadMultiply:67,NumpadAdd:69,NumLock:71,NumpadDivide:75,NumpadEnter:76,NumpadSubtract:78,F18:79,F19:80,NumpadEqual:81,Numpad0:82,Numpad1:83,Numpad2:84,Numpad3:85,Numpad4:86,Numpad5:87,Numpad6:88,Numpad7:89,F20:90,Numpad8:91,Numpad9:92,F5:96,F6:97,F7:98,F3:99,F8:100,F9:101,F11:103,F13:105,F16:106,F14:107,F10:109,F12:111,F15:113,Home:115,PageUp:116,Delete:117,F4:118,End:119,F2:120,PageDown:121,F1:122,ArrowLeft:123,ArrowRight:124,ArrowDown:125,ArrowUp:126};
const labels: Record<string,string> = {Enter:"Return",Escape:"Esc",Backspace:"Delete",Delete:"Forward Delete",ArrowLeft:"←",ArrowRight:"→",ArrowDown:"↓",ArrowUp:"↑",Comma:",",Period:".",Slash:"/",Backslash:"\\",Quote:"'",Semicolon:";",BracketLeft:"[",BracketRight:"]",Minus:"-",Equal:"=",Backquote:"`",PageUp:"Page Up",PageDown:"Page Down"};
export function captureRecordingKey(event: Pick<KeyboardEvent,"code"|"ctrlKey"|"altKey"|"shiftKey"|"metaKey"|"isComposing"|"repeat">): RecordingBinding | null {
  if (event.isComposing || event.repeat || codes[event.code] === undefined) return null;
  const modifiers=(event.metaKey?256:0)|(event.shiftKey?512:0)|(event.altKey?2048:0)|(event.ctrlKey?4096:0);
  const prefix=(event.ctrlKey?"⌃":"")+(event.altKey?"⌥":"")+(event.shiftKey?"⇧":"")+(event.metaKey?"⌘":"");
  const label=labels[event.code] ?? event.code.replace(/^Key|^Digit/, "").replace(/^Numpad/,"Keypad ");
  return {mode:"custom",kind:"keyCombination",keyCode:codes[event.code],modifiers,label:prefix+label};
}
export function singleModifier(key: string): RecordingBinding | null {
  const entry: Record<string,[RecordingKind,string]>={Control:["singleControl","⌃"],Alt:["singleOption","⌥"],Shift:["singleShift","⇧"],Meta:["singleCommand","⌘"]};
  const value=entry[key];return value?{mode:"custom",kind:value[0],label:value[1],keyCode:0,modifiers:0}:null;
}
export function recordingConflict(bindings: Record<RecordingAction,RecordingBinding>): boolean {
  const active=Object.values(bindings).filter(binding=>binding.mode==="custom");
  return active.some((binding,i)=>active.slice(0,i).some(other=>other.kind===binding.kind&&(binding.kind!=="keyCombination"||(other.keyCode===binding.keyCode&&other.modifiers===binding.modifiers))));
}

import { useEffect, useSyncExternalStore } from "react";
import messages from "./locales/messages.json";
export type Language = "system" | "en" | "ko";
export type Locale = "en" | "ko";
const eventName = "prism:language-changed";
const translations = new Map<string, {en:string;ko:string}>();
for (const [en,ko] of messages) {
  // Preserve the original wording when several source labels share a translation.
  if (!translations.has(en)) translations.set(en,{en,ko});
  if (!translations.has(ko)) translations.set(ko,{en,ko});
}
const templates = [...translations].filter(([source])=>/\{[0-9]+\}/.test(source)).map(([source,pair])=>{
  const names:string[]=[];
  const pattern=source.split(/(\{[0-9]+\})/).map(part=>{
    if (/^\{[0-9]+\}$/.test(part)) { names.push(part.slice(1,-1)); return "(.+?)"; }
    return part.replace(/[.*+?^${}()|[\]\\]/g,"\\$&");
  }).join("");
  return {pattern:new RegExp("^"+pattern+"$"),names,pair};
});
function translatedLine(source:string,locale:Locale):string {
  const trimmed=source.trim();
  const direct=translations.get(trimmed)?.[locale];
  if (direct!==undefined) return source.replace(trimmed,direct);
  for (const template of templates) {
    const match=template.pattern.exec(trimmed);
    if (match) { let value=template.pair[locale];template.names.forEach((name,i)=>{value=value.replaceAll(`{${name}}`,()=>match[i+1]);});return source.replace(trimmed,()=>value); }
  }
  return source;
}
export function languagePreference(): Language {
  try { const value=JSON.parse(localStorage.getItem("prism:preferences")??"null")?.language; return value==="en"||value==="ko"?value:"system"; }
  catch { return "system"; }
}
export function currentLocale(): Locale {
  const preference=languagePreference();
  return preference==="system"?(navigator.language.toLowerCase().startsWith("ko")?"ko":"en"):preference;
}
/** Only call for product-owned copy, never conversation bodies, names, paths or model output. */
export function t(source: string, params: Record<string,string|number> = {}, locale = currentLocale()): string {
  const value=source.split("\n").map(line=>translatedLine(line,locale)).join("\n");
  return value.replace(/\{([^}]+)\}/g,(token,name)=>Object.hasOwn(params,name)?String(params[name]):token);
}
export function bilingual(source:string):string[] { return [t(source,{},"en"),t(source,{},"ko")]; }
export function notifyLanguageChanged() { window.dispatchEvent(new Event(eventName)); }
function subscribe(callback:()=>void) {
  const storage=(event:StorageEvent)=>{if(event.key==="prism:preferences"||event.key===null)callback();};
  window.addEventListener(eventName,callback); window.addEventListener("storage",storage); window.addEventListener("languagechange",callback);
  return ()=>{window.removeEventListener(eventName,callback);window.removeEventListener("storage",storage);window.removeEventListener("languagechange",callback);};
}
export function useLocale():Locale {
  const locale=useSyncExternalStore(subscribe,currentLocale,():Locale=>"en");
  useEffect(()=>{document.documentElement.lang=locale;},[locale]);
  return locale;
}

/** Translate built-in metadata while preserving all user-owned labels and values. */
export function localizeCommand<T extends import("@prism/command-core").CommandItem>(item:T):T {
  const builtIn = ["prism","system"].includes(item.providerId);
  const title = builtIn ? t(item.title) : item.title;
  return {...item, title, section:t(item.section),
    subtitle:builtIn && item.subtitle ? t(item.subtitle) : item.subtitle,
    keywords:builtIn ? [...(item.keywords??[]),...bilingual(item.title)] : item.keywords,
    actions:item.actions.map(action=>({...action,title: /^Apply /.test(action.title)?t("Apply {0}",{0:title}):t(action.title)})),
  };
}

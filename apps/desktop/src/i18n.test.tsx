import {act} from "react";
import {createRoot} from "react-dom/client";
import {afterEach,beforeEach,expect,it} from "vitest";
import {currentLocale,localizeCommand,notifyLanguageChanged,t,useLocale} from "./i18n";
import {rankCommands} from "@prism/command-core";
import {createPrismProvider} from "./providers/prism";
let host:HTMLDivElement;let root:ReturnType<typeof createRoot>;
beforeEach(()=>{localStorage.clear();Object.defineProperty(navigator,"language",{configurable:true,value:"en-US"});host=document.createElement("div");document.body.append(host);root=createRoot(host);});
afterEach(async()=>{await act(async()=>root.unmount());host.remove();});
function Surface(){useLocale();return <><button aria-label={t("Search conversations")}>{t("Settings")}</button><p>{t("대화를 저장하지 못했습니다.")}</p></>;}
it("switches visible labels and native error copy immediately and handles changes from another window",async()=>{
 await act(async()=>root.render(<Surface/>));expect(host.textContent).toContain("Settings");
 await act(async()=>{localStorage.setItem("prism:preferences",JSON.stringify({language:"ko"}));notifyLanguageChanged();});
 expect(host.querySelector("button")?.textContent).toBe("설정");expect(host.querySelector("button")?.getAttribute("aria-label")).toBe("대화 검색");expect(document.documentElement.lang).toBe("ko");
 await act(async()=>{localStorage.setItem("prism:preferences",JSON.stringify({language:"en"}));window.dispatchEvent(new StorageEvent("storage",{key:"prism:preferences"}));});
 expect(host.textContent).toContain("Could not save the conversation.");expect(document.documentElement.lang).toBe("en");
});
it("falls back to system and preserves interpolation values and user-owned command names",()=>{
 localStorage.setItem("prism:preferences",JSON.stringify({language:"invalid"}));expect(currentLocale()).toBe("en");
 Object.defineProperty(navigator,"language",{configurable:true,value:"ko-KR"});expect(currentLocale()).toBe("ko");
 expect(t("Delete {0}",{0:"$& {1} Settings"})).toBe("$& {1} Settings 삭제");
 const item=localizeCommand({id:"library:1",providerId:"library",title:"Settings",subtitle:"/Users/Settings",section:"Saved links",kind:"command" as const,actions:[{id:"library-open",title:"Open"}]});
 expect(item.title).toBe("Settings");expect(item.subtitle).toBe("/Users/Settings");expect(item.actions[0].title).toBe("열기");
});
it("finds built-in commands by either language after switching an already-created provider",async()=>{
 const provider=createPrismProvider();const signal=new AbortController().signal;
 for(const language of ["ko","en"]){localStorage.setItem("prism:preferences",JSON.stringify({language}));const items=await provider.search("settings",signal);
  expect(rankCommands(items,"설정")[0].id).toBe("prism:preferences");expect(rankCommands(items,"Settings")[0].id).toBe("prism:preferences");
  expect(items.find(i=>i.id==="prism:preferences")?.title).toBe(language==="ko"?"설정":"Settings");
 }
});

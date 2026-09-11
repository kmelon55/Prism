import { AiUsageChart } from "./AiUsageChart";
import { useCallback, useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { RefreshCw } from "lucide-react";
import { t, useLocale } from "./i18n";
import { AnimatedDetails } from "./settings/InterfaceMotion";
import { emptyUsageTotals, featureName, loadUsage, rowCost, usageCost, usageProviderName, type UsageSummary } from "./providers/aiUsage";
import "./aiUsage.css";
export function AiUsage({ nativeRuntime }: { nativeRuntime: boolean }) {
  useLocale();
  const [usage, setUsage] = useState<UsageSummary>();
  const [error, setError] = useState("");
  const [savingError, setSavingError] = useState("");
  const [revision, setRevision] = useState(0);
  const refresh = useCallback(() => setRevision(n => n + 1), []);
  useEffect(() => {
    if (!nativeRuntime) return;
    let alive = true;
    void loadUsage().then(value => { if (alive) { if (!value?.month || !Array.isArray(value.recent)) throw new Error(); setUsage(value); setError(""); } })
      .catch(() => { if (alive) setError(t("Could not read AI usage.")); });
    return () => { alive = false; };
  }, [nativeRuntime, revision]);
  useEffect(() => {
    if (!nativeRuntime) return;
    let disposed = false;
    const stops: (() => void)[] = [];
    const register = (promise: Promise<() => void>) => { void promise.then(stop => { if (disposed) stop(); else stops.push(stop); }).catch(() => { if (!disposed) setError(t("Could not watch AI usage. Refresh to update.")); }); };
    register(listen("prism:ai-usage-changed", refresh));
    register(listen("prism:ai-usage-error", () => setSavingError(t("Could not save AI usage."))));
    window.addEventListener("focus", refresh);
    return () => { disposed = true; stops.forEach(stop => stop()); window.removeEventListener("focus", refresh); };
  }, [nativeRuntime, refresh]);
  const data: UsageSummary = usage ?? {month:emptyUsageTotals,allTime:emptyUsageTotals,features:[],breakdown:[],daily:[],recent:[]};
  return <section className="ai-usage" aria-label={t("AI usage")}>
    <div className="usage-heading"><div><h3>{t("AI usage")}</h3><span>{t("This month")} · {t("This device · USD")}</span></div><button type="button" className="settings-toolbar-button" aria-label={t("Refresh AI usage")} disabled={!nativeRuntime} onClick={() => {setSavingError("");refresh();}}><RefreshCw size={14}/></button></div>
    {error || savingError ? <p className="ai-usage-note" role="alert">{savingError || error}</p> : null}
    {nativeRuntime && !usage ? (!error && <p className="ai-usage-note" role="status">{t("Loading…")}</p>) : <>
      <div className="usage-totals"><div><span>{t("Cost")}</span><strong>{usageCost(data.month)}</strong></div><div><span>{t("Tokens")}</span><strong>{(data.month.inputTokens+data.month.outputTokens).toLocaleString()}{data.month.unknownTokenRequests>0 && <small> + ?</small>}</strong></div><div><span>{t("Requests")}</span><strong>{data.month.requests.toLocaleString()}</strong></div></div>
      <AiUsageChart usage={data}/>
      {!nativeRuntime && <p className="ai-usage-note">{t("Usage appears after using AI in the desktop app.")}</p>}
      {data.month.unknownCostRequests>0 && <p className="ai-usage-note">{t("{0} requests have no reported cost.",{0:data.month.unknownCostRequests})}</p>}
      {data.month.unknownTokenRequests>0 && <p className="ai-usage-note">{t("Some tokens unavailable")}</p>}
      <AnimatedDetails className="ai-usage-details"><summary>{t("Usage details")}</summary>
        <div className="usage-table-scroll"><table className="usage-table"><thead><tr><th>{t("Feature")}</th><th>{t("Model")}</th><th>{t("Provider")}</th><th>{t("Tokens")}</th><th>{t("Cost")}</th></tr></thead><tbody>{(data.breakdown ?? []).map(row=><tr key={`${row.feature}/${row.provider}/${row.model}`}><td>{featureName(row.feature)}</td><td>{row.model || "—"}</td><td>{usageProviderName(row.provider)}</td><td>{(row.inputTokens+row.outputTokens).toLocaleString()}{row.unknownTokenRequests ? " + ?" : ""}</td><td>{usageCost(row)}</td></tr>)}</tbody></table></div>
        <div className="ai-usage-line"><span>{t("All time")}</span><span>{usageCost(data.allTime)} · {t("{0} requests",{"0":data.allTime.requests.toLocaleString()})}</span></div>
        {data.recent.length>0 && <><p className="ai-usage-note">{t("Latest 12 requests")}</p><div className="ai-usage-history">{data.recent.map(row=><div className="ai-usage-line" key={row.id}><span>{featureName(row.feature)}<small>{new Date(row.startedAt).toLocaleString()} · {usageProviderName(row.provider)} · {row.model}{row.status==="unconfirmed"?` · ${t("Unconfirmed")}`:""}</small></span><span>{rowCost(row)}<small>{row.inputTokens != null && row.outputTokens != null ? t("{0} in / {1} out",{0:row.inputTokens.toLocaleString(),1:row.outputTokens.toLocaleString()}) : t("Tokens unavailable")}</small></span></div>)}</div></>}
        <p className="ai-usage-note">{t("Recorded on this device from now on. ≈ is a base-rate estimate; + ? means some costs are unavailable. Interrupted requests may still be billed. Provider invoices may differ.")}</p>
        <p className="ai-usage-note">{t("Only usage metadata is saved. No audio or dictated text is stored in usage history.")}</p>
      </AnimatedDetails>
    </>}
  </section>;
}

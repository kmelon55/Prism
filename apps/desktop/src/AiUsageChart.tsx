import { useId, useState } from "react";
import { formatAiPrice } from "./providers/ai";
import { featureName, groupUsage, metricValue, monthDays, usageCost, usageProviderName, type UsageGrouping, type UsageMetric, type UsageSummary, type UsageTotals } from "./providers/aiUsage";
import { t } from "./i18n";
const palette = ["#a89bea", "#83b6d3", "#a0c9b4", "#d9a1b7", "#d3bb8f", "#909fd4"];
function metricLabel(value: UsageTotals, metric: UsageMetric) {
  return metric === "cost" ? usageCost(value) : metric === "tokens" ? `${(value.inputTokens + value.outputTokens).toLocaleString()}${value.unknownTokenRequests ? " + ?" : ""}` : value.requests.toLocaleString();
}
export function AiUsageChart({ usage }: { usage: UsageSummary }) {
  const [metric,setMetric] = useState<UsageMetric>("cost");
  const [group,setGroup] = useState<UsageGrouping>("feature");
  const [hover,setHover] = useState<number>();
  const gradient = useId().replace(/:/g,"");
  const daily = monthDays(usage.daily ?? []);
  const elapsed = daily.filter(day=>!day.future);
  const max = Math.max(...elapsed.map(day=>metricValue(day,metric)),0);
  const y = (n:number) => 126 - (max ? n/max*102 : 0);
  const x = (index:number) => 18 + index/(daily.length-1)*584;
  const line = elapsed.map((day,index)=>`${index ? "L" : "M"}${x(index)},${y(metricValue(day,metric))}`).join(" ");
  const focused = hover == null ? undefined : daily[hover];
  const groups = groupUsage(usage.breakdown ?? [],group,metric);
  const largest = Math.max(...groups.map(row=>metricValue(row,metric)),0);
  const total = metricValue(usage.month,metric);
  const allUnknown = usage.month.requests > 0 && ((metric === "cost" && usage.month.unknownCostRequests === usage.month.requests) || (metric === "tokens" && usage.month.unknownTokenRequests === usage.month.requests));
  return <>
    <div className="usage-chart-toolbar"><span>{focused ? `${new Date(`${focused.day}T12:00:00`).toLocaleDateString()} · ${metricLabel(focused,metric)}` : t("Daily usage")}</span><div className="usage-segments" role="group" aria-label={t("Chart metric")}>{([['cost','Cost'],['tokens','Tokens'],['requests','Requests']] as const).map(([id,label])=><button type="button" key={id} aria-pressed={metric===id} onClick={()=>setMetric(id)}>{t(label)}</button>)}</div></div>
    <div className="usage-timeline" onMouseLeave={()=>setHover(undefined)}>
      <svg viewBox="0 0 620 155" role="group" aria-label={t("Daily AI usage chart")}>
        <defs><linearGradient id={gradient} x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stopColor="#a89bea" stopOpacity=".27"/><stop offset="100%" stopColor="#a89bea" stopOpacity=".015"/></linearGradient></defs>
        {[24,75,126].map(pos=><line key={pos} x1="18" x2="602" y1={pos} y2={pos} className="usage-gridline"/>)}
        <text x="602" y="15" textAnchor="end" className="usage-axis">{allUnknown ? "—" : metric==="cost"?formatAiPrice(max):max.toLocaleString()}</text>
        {usage.month.requests>0 && !allUnknown && <><path d={`${line} L${x(elapsed.length-1)},126 L18,126 Z`} fill={`url(#${gradient})`}/><path d={line} fill="none" stroke="#a89bea" strokeWidth="2.5" strokeLinejoin="round" strokeLinecap="round"/></>}
        {elapsed.map((day,index)=><g key={day.day} tabIndex={0} role="img" aria-label={`${day.day}: ${metricLabel(day,metric)}`} onFocus={()=>setHover(index)} onBlur={()=>setHover(undefined)} onMouseEnter={()=>setHover(index)}>
          <rect x={x(index)-9} y="20" width="18" height="110" fill="transparent"/>
          {!allUnknown && (day.requests>0 || hover===index) && <circle cx={x(index)} cy={y(metricValue(day,metric))} r={hover===index?4:2.5} fill="#a89bea"/>}
          <title>{day.day}: {metricLabel(day,metric)}</title>
        </g>)}
        {[0,Math.floor((daily.length-1)/2),daily.length-1].map(index=><text key={index} x={x(index)} y="150" textAnchor={index===0?"start":index===daily.length-1?"end":"middle"} className="usage-axis">{index+1}</text>)}
      </svg>
      {!usage.month.requests && <div className="usage-chart-empty">{t("Your usage will appear here")}</div>}
      {allUnknown && <div className="usage-chart-empty">{t(metric === "cost" ? "Cost unavailable" : "Tokens unavailable")}</div>}
    </div>
    <div className="usage-breakdown-heading"><div className="usage-segments" role="group" aria-label={t("Group usage by")}>{([['feature','Feature'],['model','Model'],['provider','Provider']] as const).map(([id,label])=><button type="button" key={id} aria-pressed={group===id} onClick={()=>setGroup(id)}>{t(label)}</button>)}</div><small>{t(metric === "cost" ? "Known costs" : metric === "tokens" ? "Reported tokens" : "Requests")}</small></div>
    <div className="usage-breakdown" aria-label={t("Usage breakdown")}>{groups.map((row,index)=> {
      const value=metricValue(row,metric); const unavailable = (metric === "cost" && row.unknownCostRequests === row.requests) || (metric === "tokens" && row.unknownTokenRequests === row.requests); const name=group === "feature" ? featureName(row.name) : group === "provider" ? usageProviderName(row.name) : row.name.replace(/^[^ ]+(?= \/ )/,usageProviderName(row.name.split(" / ")[0]));
      return <div className="usage-bar-row" key={row.name}><div className="usage-bar-label"><span title={name}><i style={{background:palette[index%palette.length]}}/>{name}</span><span>{metricLabel(row,metric)}<small>{total && !unavailable ? `${Math.round(value/total*100)}%` : "—"}</small></span></div><div className="usage-bar-track"><div style={{width:`${largest ? value/largest*100 : 0}%`,background:palette[index%palette.length]}}/></div></div>;
    })}{!groups.length && <p className="ai-usage-note">{t("No usage yet")}</p>}</div>
  </>;
}

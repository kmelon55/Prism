//! Local metadata ledger. Never persist prompts, transcripts, audio, keys, or response bodies.
use rusqlite::{params, Connection};
use serde::Serialize;
use serde_json::Value;
use std::{
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use tauri::{Emitter, Manager};

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Measurement {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub cost_usd: Option<f64>,
    pub cost_kind: String,
}
fn number(v: &Value) -> Option<f64> {
    v.as_f64()
        .or_else(|| v.as_str()?.parse().ok())
        .filter(|n| n.is_finite() && *n >= 0.0)
}
pub fn measure(value: &Value, prices: Option<(f64, f64)>) -> Measurement {
    let usage = &value["usage"];
    let input_tokens = usage["input_tokens"]
        .as_u64()
        .or_else(|| usage["prompt_tokens"].as_u64());
    let output_tokens = usage["output_tokens"]
        .as_u64()
        .or_else(|| usage["completion_tokens"].as_u64());
    let reported = number(&usage["cost"])
        .or_else(|| number(&value["providerMetadata"]["gateway"]["cost"]))
        .or_else(|| number(&value["provider_metadata"]["gateway"]["cost"]));
    let estimate = prices.and_then(|(input, output)| {
        // Only estimate text requests with complete usage. STT audio units differ.
        let cost = (input_tokens? as f64 * input + output_tokens? as f64 * output) / 1_000_000.0;
        (cost.is_finite() && cost >= 0.0).then_some(cost)
    });
    Measurement {
        input_tokens,
        output_tokens,
        cost_usd: reported.or(estimate),
        cost_kind: if reported.is_some() {
            "reported"
        } else if estimate.is_some() {
            "estimated"
        } else {
            "unknown"
        }
        .into(),
    }
}
fn connect(path: &Path) -> Result<Connection, String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|_| "Could not save AI usage.")?;
    }
    let db = Connection::open(path).map_err(|_| "Could not read AI usage.")?;
    db.busy_timeout(std::time::Duration::from_secs(3))
        .map_err(|_| "Could not read AI usage.")?;
    db.execute_batch("CREATE TABLE IF NOT EXISTS requests (
        id INTEGER PRIMARY KEY, started_at INTEGER NOT NULL, feature TEXT NOT NULL,
        provider TEXT NOT NULL, model TEXT NOT NULL, status TEXT NOT NULL,
        input_tokens INTEGER, output_tokens INTEGER, cost_usd REAL, cost_kind TEXT NOT NULL DEFAULT 'unknown'
    ); CREATE INDEX IF NOT EXISTS requests_started ON requests(started_at);")
        .map_err(|_| "Could not read AI usage.")?;
    Ok(db)
}
fn path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .app_data_dir()
        .map_err(|_| "Could not read AI usage.")?
        .join("ai-usage-v1.sqlite"))
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}
fn insert(db: &Connection, feature: &str, provider: &str, model: &str) -> Result<i64, String> {
    db.execute("INSERT INTO requests(started_at,feature,provider,model,status) VALUES (?1,?2,?3,?4,'unconfirmed')", params![now(),feature,provider,model]).map_err(|_| "Could not save AI usage.")?;
    Ok(db.last_insert_rowid())
}
fn update(db: &Connection, id: i64, measurement: &Measurement, status: &str) -> Result<(), String> {
    db.execute("UPDATE requests SET status=?2,input_tokens=?3,output_tokens=?4,cost_usd=?5,cost_kind=?6 WHERE id=?1",
        params![id,status,measurement.input_tokens,measurement.output_tokens,measurement.cost_usd,measurement.cost_kind]).map_err(|_| "Could not save AI usage.")?;
    Ok(())
}
/// Insert before dispatch so interrupted/crashed requests remain visibly unconfirmed.
pub struct Ticket {
    app: tauri::AppHandle,
    path: PathBuf,
    id: i64,
}
impl Ticket {
    pub fn start(
        app: &tauri::AppHandle,
        feature: &str,
        provider: &str,
        model: &str,
    ) -> Result<Self, String> {
        let path = path(app)?;
        let id = insert(&connect(&path)?, feature, provider, model)?;
        let _ = app.emit("prism:ai-usage-changed", ());
        Ok(Self {
            app: app.clone(),
            path,
            id,
        })
    }
    pub fn finish(&self, measurement: &Measurement, status: &str) {
        if connect(&self.path)
            .and_then(|db| update(&db, self.id, measurement, status))
            .is_err()
        {
            let _ = self
                .app
                .emit("prism:ai-usage-error", "Could not save AI usage.");
        }
        let _ = self.app.emit("prism:ai-usage-changed", ());
    }
}
#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Totals {
    requests: u64,
    input_tokens: u64,
    output_tokens: u64,
    known_cost_usd: f64,
    unknown_cost_requests: u64,
    unknown_token_requests: u64,
    estimated_requests: u64,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageRow {
    id: i64,
    started_at: i64,
    feature: String,
    provider: String,
    model: String,
    status: String,
    #[serde(flatten)]
    measurement: Measurement,
}
#[derive(Serialize)]
pub struct FeatureTotal {
    feature: String,
    #[serde(flatten)]
    totals: Totals,
}
#[derive(Serialize)]
pub struct Breakdown {
    feature: String,
    provider: String,
    model: String,
    #[serde(flatten)]
    totals: Totals,
}
#[derive(Serialize)]
pub struct Daily {
    day: String,
    #[serde(flatten)]
    totals: Totals,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    month: Totals,
    all_time: Totals,
    features: Vec<FeatureTotal>,
    breakdown: Vec<Breakdown>,
    daily: Vec<Daily>,
    recent: Vec<UsageRow>,
}
const TOTALS: &str = "COUNT(*),COALESCE(SUM(input_tokens),0),COALESCE(SUM(output_tokens),0),COALESCE(SUM(cost_usd),0),COALESCE(SUM(cost_usd IS NULL),0),COALESCE(SUM(input_tokens IS NULL OR output_tokens IS NULL),0),COALESCE(SUM(cost_kind='estimated'),0)";
fn totals(row: &rusqlite::Row<'_>, offset: usize) -> rusqlite::Result<Totals> {
    Ok(Totals {
        requests: row.get(offset)?,
        input_tokens: row.get(offset + 1)?,
        output_tokens: row.get(offset + 2)?,
        known_cost_usd: row.get(offset + 3)?,
        unknown_cost_requests: row.get(offset + 4)?,
        unknown_token_requests: row.get(offset + 5)?,
        estimated_requests: row.get(offset + 6)?,
    })
}
fn summary(db: &Connection, since: i64) -> Result<Summary, String> {
    (|| -> rusqlite::Result<Summary> {
        let month = db.query_row(&format!("SELECT {TOTALS} FROM requests WHERE started_at>=?1"), [since], |r| totals(r,0))?;
        let all_time = db.query_row(&format!("SELECT {TOTALS} FROM requests"), [], |r| totals(r,0))?;
        let mut query = db.prepare(&format!("SELECT feature,{TOTALS} FROM requests WHERE started_at>=?1 GROUP BY feature"))?;
        let features = query.query_map([since], |r| Ok(FeatureTotal { feature:r.get(0)?,totals:totals(r,1)? }))?.collect::<rusqlite::Result<Vec<_>>>()?;
        let mut query = db.prepare("SELECT id,started_at,feature,provider,model,status,input_tokens,output_tokens,cost_usd,cost_kind FROM requests ORDER BY id DESC LIMIT 12")?;
        let recent = query.query_map([], |r| Ok(UsageRow { id:r.get(0)?,started_at:r.get(1)?,feature:r.get(2)?,provider:r.get(3)?,model:r.get(4)?,status:r.get(5)?,measurement:Measurement {input_tokens:r.get(6)?,output_tokens:r.get(7)?,cost_usd:r.get(8)?,cost_kind:r.get(9)?} }))?.collect::<rusqlite::Result<Vec<_>>>()?;
        let mut query = db.prepare(&format!("SELECT feature,provider,model,{TOTALS} FROM requests WHERE started_at>=?1 GROUP BY feature,provider,model ORDER BY COALESCE(SUM(cost_usd),0) DESC"))?;
        let breakdown = query.query_map([since], |r| Ok(Breakdown {feature:r.get(0)?,provider:r.get(1)?,model:r.get(2)?,totals:totals(r,3)?}))?.collect::<rusqlite::Result<Vec<_>>>()?;
        let mut query = db.prepare(&format!("SELECT strftime('%Y-%m-%d',started_at/1000,'unixepoch','localtime') AS day,{TOTALS} FROM requests WHERE started_at>=?1 GROUP BY day ORDER BY day"))?;
        let daily = query.query_map([since], |r| Ok(Daily {day:r.get(0)?,totals:totals(r,1)?}))?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(Summary { month, all_time, features, breakdown, daily, recent })
    })().map_err(|_| "Could not read AI usage.".into())
}
#[tauri::command]
pub async fn ai_usage_summary(app: tauri::AppHandle, since: i64) -> Result<Summary, String> {
    if since < 0 || since > now() {
        return Err("Invalid usage period.".into());
    }
    tauri::async_runtime::spawn_blocking(move || summary(&connect(&path(&app)?)?, since))
        .await
        .map_err(|_| "Could not read AI usage.".to_string())?
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn costs_preserve_unknown_and_prefer_reported_over_estimates() {
        assert_eq!(measure(&json!({}), None).cost_usd, None);
        assert_eq!(
            measure(
                &json!({"usage":{"cost":"0.003","prompt_tokens":100,"completion_tokens":20}}),
                Some((99.0, 99.0))
            )
            .cost_usd,
            Some(0.003)
        );
        assert_eq!(
            measure(&json!({"usage":{"cost":0}}), None).cost_usd,
            Some(0.0)
        );
        let m = measure(
            &json!({"usage":{"input_tokens":1000,"output_tokens":500}}),
            Some((1.0, 2.0)),
        );
        assert_eq!(m.cost_usd, Some(0.002));
        assert_eq!(m.cost_kind, "estimated");
        assert_eq!(
            measure(&json!({"usage":{"input_tokens":1000}}), Some((1.0, 2.0))).cost_usd,
            None
        );
        assert_eq!(
            measure(&json!({"usage":{"cost":"NaN"}}), None).cost_usd,
            None
        );
    }
    #[test]
    fn aggregate_all_requests_by_tuple_and_day_beyond_recent_limit() {
        let db = connect(std::path::Path::new(":memory:")).unwrap();
        for _ in 0..20 { insert(&db, "cleanup", "vercel", "same").unwrap(); }
        insert(&db, "prompt", "vercel", "same").unwrap();
        insert(&db, "prompt", "openai", "same").unwrap();
        let s = summary(&db, 0).unwrap();
        assert_eq!(s.recent.len(), 12);
        assert_eq!(s.month.requests, 22);
        assert_eq!(s.breakdown.len(), 3);
        assert_eq!(s.breakdown.iter().find(|r| r.feature == "cleanup").unwrap().totals.requests, 20);
        assert_eq!(s.daily.iter().map(|r| r.totals.requests).sum::<u64>(), 22);
        assert!(s.daily.iter().all(|r| r.day.len() == 10));
    }
    #[test]
    fn ledger_survives_reopen_and_does_not_double_count_completion() {
        let path = std::env::temp_dir().join(format!("prism-usage-{}.sqlite", std::process::id()));
        let db = connect(&path).unwrap();
        db.execute("DELETE FROM requests", []).unwrap();
        let a = insert(&db, "cleanup", "vercel", "fixture/model").unwrap();
        insert(&db, "transcription", "custom", "fixture").unwrap();
        let m = measure(
            &json!({"usage":{"cost":0.002,"input_tokens":100,"output_tokens":30}}),
            None,
        );
        update(&db, a, &m, "completed").unwrap();
        update(&db, a, &m, "completed").unwrap();
        drop(db);
        let s = summary(&connect(&path).unwrap(), 0).unwrap();
        assert_eq!(s.month.requests, 2);
        assert_eq!(s.month.input_tokens, 100);
        assert_eq!(s.month.unknown_cost_requests, 1);
        assert_eq!(s.month.known_cost_usd, 0.002);
        assert_eq!(
            summary(&connect(&path).unwrap(), now() + 100)
                .unwrap()
                .month
                .requests,
            0
        );
        std::fs::remove_file(path).unwrap();
    }
}

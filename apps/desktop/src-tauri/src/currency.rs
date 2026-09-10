use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    path::PathBuf,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::async_runtime::Mutex;

// The renderer cannot supply a URL, currency, amount, or search string to this request.
const ENDPOINT: &str = "https://api.frankfurter.dev/v2/rates?base=EUR&providers=ECB";
const MAX_BYTES: usize = 64 * 1024;
const HOUR: u64 = 60 * 60;
const MAX_AGE: u64 = 7 * 24 * HOUR;
const UNAVAILABLE: &str = "Exchange rates are unavailable. Check your connection and try again.";

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RateSnapshot {
    date: String,
    fetched_at: u64,
    rates: BTreeMap<String, f64>,
    stale: bool,
}

#[derive(Deserialize)]
struct RateRow {
    date: String,
    base: String,
    quote: String,
    rate: f64,
}

#[derive(Default)]
struct Cache {
    snapshot: Option<RateSnapshot>,
    disk_loaded: bool,
    retry_after: u64,
}

#[derive(Default)]
pub struct CurrencyRates(Mutex<Cache>);

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn valid_snapshot(snapshot: &RateSnapshot, now: u64) -> bool {
    let Ok(date) = chrono::NaiveDate::parse_from_str(&snapshot.date, "%Y-%m-%d") else {
        return false;
    };
    let Some(timestamp) = date.and_hms_opt(0, 0, 0) else {
        return false;
    };
    let rate_time = timestamp.and_utc().timestamp();
    rate_time >= 0
        && rate_time as u64 <= now
        && now - rate_time as u64 <= MAX_AGE
        && snapshot.fetched_at <= now
        && now - snapshot.fetched_at <= MAX_AGE
        && (2..=64).contains(&snapshot.rates.len())
        && snapshot.rates.get("EUR") == Some(&1.0)
        && snapshot.rates.iter().all(|(code, rate)| {
            code.len() == 3
                && code.bytes().all(|byte| byte.is_ascii_uppercase())
                && rate.is_finite()
                && *rate > 0.0
                && *rate <= 1_000_000_000.0
        })
}

fn parse_rates(bytes: &[u8], now: u64) -> Result<RateSnapshot, String> {
    if bytes.len() > MAX_BYTES {
        return Err(UNAVAILABLE.into());
    }
    let rows: Vec<RateRow> = serde_json::from_slice(bytes).map_err(|_| UNAVAILABLE)?;
    if rows.is_empty() || rows.len() > 64 {
        return Err(UNAVAILABLE.into());
    }
    let mut snapshot = RateSnapshot {
        date: rows[0].date.clone(),
        fetched_at: now,
        rates: BTreeMap::new(),
        stale: false,
    };
    for row in rows {
        if row.base != "EUR"
            || row.date != snapshot.date
            || snapshot.rates.insert(row.quote, row.rate).is_some()
        {
            return Err(UNAVAILABLE.into());
        }
    }
    // Some provider responses omit the base currency's identity record.
    snapshot.rates.entry("EUR".into()).or_insert(1.0);
    if !valid_snapshot(&snapshot, now) {
        return Err(UNAVAILABLE.into());
    }
    Ok(snapshot)
}

async fn fetch_rates() -> Result<RateSnapshot, String> {
    let client = reqwest::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(4))
        .build()
        .map_err(|_| UNAVAILABLE)?;
    let mut response = client
        .get(ENDPOINT)
        .send()
        .await
        .and_then(reqwest::Response::error_for_status)
        .map_err(|_| UNAVAILABLE)?;
    if response
        .content_length()
        .is_some_and(|size| size > MAX_BYTES as u64)
    {
        return Err(UNAVAILABLE.into());
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| UNAVAILABLE)? {
        if body.len() + chunk.len() > MAX_BYTES {
            return Err(UNAVAILABLE.into());
        }
        body.extend_from_slice(&chunk);
    }
    parse_rates(&body, now_seconds())
}

impl CurrencyRates {
    pub async fn load(&self, cache_root: PathBuf) -> Result<RateSnapshot, String> {
        // Serialize refreshes across windows. Searches share one table, never one request per amount.
        let mut cache = self.0.lock().await;
        let file = cache_root.join("currency-ecb-v1.json");
        if !cache.disk_loaded {
            let file = file.clone();
            cache.snapshot = tauri::async_runtime::spawn_blocking(move || {
                if std::fs::metadata(&file).ok()?.len() > MAX_BYTES as u64 {
                    return None;
                }
                let bytes = std::fs::read(file).ok()?;
                let snapshot: RateSnapshot = serde_json::from_slice(&bytes).ok()?;
                valid_snapshot(&snapshot, now_seconds()).then_some(snapshot)
            })
            .await
            .ok()
            .flatten();
            cache.disk_loaded = true;
        }
        let now = now_seconds();
        if let Some(snapshot) = cache
            .snapshot
            .as_ref()
            .filter(|value| valid_snapshot(value, now) && now - value.fetched_at < HOUR)
        {
            return Ok(snapshot.clone());
        }
        if now >= cache.retry_after {
            match fetch_rates().await {
                Ok(snapshot) => {
                    cache.snapshot = Some(snapshot.clone());
                    cache.retry_after = 0;
                    let saved = snapshot.clone();
                    let _ = tauri::async_runtime::spawn_blocking(move || -> std::io::Result<()> {
                        std::fs::create_dir_all(&cache_root)?;
                        let temporary = file.with_extension("tmp");
                        std::fs::write(&temporary, serde_json::to_vec(&saved)?)?;
                        std::fs::rename(temporary, file)
                    })
                    .await;
                    return Ok(snapshot);
                }
                Err(_) => cache.retry_after = now_seconds() + 15,
            }
        }
        cache
            .snapshot
            .as_ref()
            .filter(|value| valid_snapshot(value, now_seconds()))
            .map(|snapshot| RateSnapshot {
                stale: true,
                ..snapshot.clone()
            })
            .ok_or_else(|| UNAVAILABLE.into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const NOW: u64 = 1_788_652_800; // 2026-09-06 UTC
    fn fixture() -> Vec<u8> {
        br#"[{"date":"2026-09-04","base":"EUR","quote":"USD","rate":1.2},{"date":"2026-09-04","base":"EUR","quote":"KRW","rate":1600}]"#.to_vec()
    }

    #[test]
    fn accepts_a_dated_table_and_adds_the_base_identity() {
        let snapshot = parse_rates(&fixture(), NOW).unwrap();
        assert_eq!(snapshot.rates["EUR"], 1.0);
        assert_eq!(snapshot.rates["KRW"], 1600.0);
        assert!(!snapshot.stale);
    }

    #[test]
    fn rejects_invalid_rates_bases_dates_and_duplicates() {
        let original = String::from_utf8(fixture()).unwrap();
        for invalid in [
            original.replace("1.2", "0"),
            original.replace("1.2", "-1"),
            original.replace("1.2", "1e999"),
            original.replace("EUR", "USD"),
            original.replace("2026-09-04", "2026-02-30"),
            original.replace("2026-09-04", "2026-09-07"),
            original.replace("2026-09-04", "2025-09-04"),
            original.replacen("2026-09-04", "2026-09-03", 1),
            original.replace("KRW", "USD"),
            original.replace("USD", "usd"),
        ] {
            assert!(parse_rates(invalid.as_bytes(), NOW).is_err(), "{invalid}");
        }
        assert!(parse_rates(&vec![b' '; MAX_BYTES + 1], NOW).is_err());
    }

    #[test]
    fn disk_cache_round_trips_and_cannot_extend_the_rate_date() {
        let snapshot = parse_rates(&fixture(), NOW).unwrap();
        let mut restored: RateSnapshot =
            serde_json::from_slice(&serde_json::to_vec(&snapshot).unwrap()).unwrap();
        assert!(valid_snapshot(&restored, NOW + HOUR));
        assert!(!valid_snapshot(&restored, NOW - 1));
        restored.fetched_at = NOW + MAX_AGE;
        assert!(!valid_snapshot(&restored, NOW + MAX_AGE));
    }

    #[test]
    fn fresh_cache_is_immediate_and_refresh_failure_is_explicit() {
        let now = now_seconds();
        let date = chrono::DateTime::from_timestamp((now - 2 * HOUR) as i64, 0)
            .unwrap()
            .format("%Y-%m-%d")
            .to_string();
        let snapshot = RateSnapshot {
            date,
            fetched_at: now,
            rates: BTreeMap::from([
                ("EUR".into(), 1.0),
                ("USD".into(), 1.2),
                ("KRW".into(), 1600.0),
            ]),
            stale: false,
        };
        let rates = CurrencyRates(Mutex::new(Cache {
            snapshot: Some(snapshot),
            disk_loaded: true,
            retry_after: now + 60,
        }));
        tauri::async_runtime::block_on(async {
            assert!(!rates.load(PathBuf::new()).await.unwrap().stale);
            rates.0.lock().await.snapshot.as_mut().unwrap().fetched_at = now - 2 * HOUR;
            assert!(rates.load(PathBuf::new()).await.unwrap().stale);
            rates.0.lock().await.snapshot.as_mut().unwrap().fetched_at = now - MAX_AGE - 1;
            assert!(rates.load(PathBuf::new()).await.is_err());
        });
    }

    #[test]
    #[ignore = "Explicit network smoke test; never runs in the normal test suite"]
    fn live_reference_table() {
        let snapshot = tauri::async_runtime::block_on(fetch_rates()).unwrap();
        assert!(snapshot.rates.contains_key("KRW"));
        assert!(snapshot.rates.contains_key("USD"));
        println!(
            "ECB via Frankfurter: {} ({} currencies)",
            snapshot.date,
            snapshot.rates.len()
        );
    }
}

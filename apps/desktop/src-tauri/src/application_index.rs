use crate::app_catalog::{self, NativeApplication};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs,
    path::Path,
    sync::{Arc, Mutex, OnceLock, RwLock},
    time::{SystemTime, UNIX_EPOCH},
};
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};

const MAX_SEARCH_RESULTS: usize = 100;

#[derive(Clone)]
pub struct ApplicationIndex {
    inner: Arc<ApplicationIndexInner>,
}

struct ApplicationIndexInner {
    applications: RwLock<Vec<IndexedApplication>>,
    database: Mutex<Connection>,
}

#[derive(Clone, Debug)]
struct IndexedApplication {
    application: NativeApplication,
    normalized_name: String,
    normalized_path: String,
    aliases: Vec<String>,
    launch_count: u32,
    last_launched_at: Option<i64>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplicationSearchResult {
    id: String,
    name: String,
    path: String,
    platform: String,
    ranking_boost: f64,
}

impl ApplicationIndex {
    pub fn open(database_path: &Path) -> Result<Self, String> {
        if let Some(parent) = database_path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!("Could not create the application index directory: {error}")
            })?;
        }

        let connection = Connection::open(database_path)
            .map_err(|error| format!("Could not open the application index: {error}"))?;
        initialize_database(&connection)?;
        let applications = load_applications(&connection)?;
        Ok(Self {
            inner: Arc::new(ApplicationIndexInner {
                applications: RwLock::new(applications),
                database: Mutex::new(connection),
            }),
        })
    }

    pub fn search(&self, raw_query: &str, limit: usize) -> Vec<ApplicationSearchResult> {
        let query = normalize(raw_query.trim());
        let now = unix_timestamp();
        let Ok(applications) = self.inner.applications.read() else {
            return Vec::new();
        };

        let mut matches = applications
            .iter()
            .filter_map(|indexed| {
                let ranking_boost =
                    frecency_bonus(indexed.launch_count, indexed.last_launched_at, now);
                let text_score = if query.is_empty() {
                    0.0
                } else {
                    let name_score = match_score(&query, &indexed.normalized_name, [6, 5, 3]);
                    let path_score = match_score(&query, &indexed.normalized_path, [1, 1, 1]);
                    name_score
                        .into_iter()
                        .chain(path_score)
                        .chain(
                            indexed
                                .aliases
                                .iter()
                                .filter_map(|alias| match_score(&query, alias, [6, 5, 3])),
                        )
                        .reduce(f64::max)?
                };

                Some((indexed, text_score + ranking_boost, ranking_boost))
            })
            .collect::<Vec<_>>();

        matches.sort_by(|(left, left_score, _), (right, right_score, _)| {
            right_score
                .total_cmp(left_score)
                .then_with(|| right.launch_count.cmp(&left.launch_count))
                .then_with(|| left.application.name.cmp(&right.application.name))
        });

        matches
            .into_iter()
            .take(limit.clamp(1, MAX_SEARCH_RESULTS))
            .map(|(indexed, _, ranking_boost)| ApplicationSearchResult {
                id: indexed.application.id.clone(),
                name: indexed.application.name.clone(),
                path: indexed.application.path.clone(),
                platform: indexed.application.platform.clone(),
                ranking_boost,
            })
            .collect()
    }

    pub fn lookup(&self, application_id: &str) -> Option<ApplicationSearchResult> {
        let now = unix_timestamp();
        self.inner
            .applications
            .read()
            .ok()?
            .iter()
            .find(|indexed| indexed.application.id == application_id)
            .map(|indexed| ApplicationSearchResult {
                id: indexed.application.id.clone(),
                name: indexed.application.name.clone(),
                path: indexed.application.path.clone(),
                platform: indexed.application.platform.clone(),
                ranking_boost: frecency_bonus(indexed.launch_count, indexed.last_launched_at, now),
            })
    }

    pub fn refresh(&self) -> Result<usize, String> {
        let discovered = app_catalog::discover();
        let mut database = self
            .inner
            .database
            .lock()
            .map_err(|_| "The application index database is unavailable.".to_string())?;
        let transaction = database
            .transaction()
            .map_err(|error| format!("Could not update the application index: {error}"))?;
        transaction
            .execute("DELETE FROM applications", [])
            .map_err(|error| {
                format!("Could not clear the previous application catalog: {error}")
            })?;

        {
            let mut statement = transaction
                .prepare(
                    "INSERT INTO applications (id, name, path, platform) VALUES (?1, ?2, ?3, ?4)",
                )
                .map_err(|error| {
                    format!("Could not prepare the application catalog update: {error}")
                })?;
            for application in &discovered {
                statement
                    .execute(params![
                        application.id,
                        application.name,
                        application.path,
                        application.platform
                    ])
                    .map_err(|error| {
                        format!("Could not save an application catalog entry: {error}")
                    })?;
            }
        }

        transaction
            .commit()
            .map_err(|error| format!("Could not commit the application catalog: {error}"))?;
        let usage = load_usage(&database)?;
        drop(database);

        let indexed = discovered
            .into_iter()
            .map(|application| IndexedApplication::new(application, &usage))
            .collect::<Vec<_>>();
        let count = indexed.len();
        *self
            .inner
            .applications
            .write()
            .map_err(|_| "The application index is unavailable.".to_string())? = indexed;
        Ok(count)
    }

    pub fn contains(&self, application_id: &str, target: &str) -> bool {
        self.inner
            .applications
            .read()
            .map(|applications| {
                applications.iter().any(|indexed| {
                    indexed.application.id == application_id && indexed.application.path == target
                })
            })
            .unwrap_or(false)
    }

    pub fn record_launch(&self, application_id: &str) -> Result<(), String> {
        let launched_at = unix_timestamp();
        {
            let database = self
                .inner
                .database
                .lock()
                .map_err(|_| "The application index database is unavailable.".to_string())?;
            database
                .execute(
                    "INSERT INTO application_usage (application_id, launch_count, last_launched_at)
                     VALUES (?1, 1, ?2)
                     ON CONFLICT(application_id) DO UPDATE SET
                       launch_count = launch_count + 1,
                       last_launched_at = excluded.last_launched_at",
                    params![application_id, launched_at],
                )
                .map_err(|error| format!("Could not record application usage: {error}"))?;
        }

        if let Ok(mut applications) = self.inner.applications.write() {
            if let Some(indexed) = applications
                .iter_mut()
                .find(|indexed| indexed.application.id == application_id)
            {
                indexed.launch_count = indexed.launch_count.saturating_add(1);
                indexed.last_launched_at = Some(launched_at);
            }
        }
        Ok(())
    }
}

impl IndexedApplication {
    fn new(application: NativeApplication, usage: &HashMap<String, (u32, Option<i64>)>) -> Self {
        let (launch_count, last_launched_at) =
            usage.get(&application.id).copied().unwrap_or((0, None));
        Self {
            normalized_name: normalize(&application.name),
            normalized_path: normalize(&application.path),
            aliases: common_application_aliases(&application.name),
            application,
            launch_count,
            last_launched_at,
        }
    }
}

fn initialize_database(connection: &Connection) -> Result<(), String> {
    connection
        .execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA busy_timeout = 5000;
             CREATE TABLE IF NOT EXISTS applications (
               id TEXT PRIMARY KEY,
               name TEXT NOT NULL,
               path TEXT NOT NULL UNIQUE,
               platform TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS application_usage (
               application_id TEXT PRIMARY KEY,
               launch_count INTEGER NOT NULL DEFAULT 0,
               last_launched_at INTEGER
             );",
        )
        .map_err(|error| format!("Could not initialize the application index: {error}"))
}

fn load_applications(connection: &Connection) -> Result<Vec<IndexedApplication>, String> {
    let usage = load_usage(connection)?;
    let mut statement = connection
        .prepare("SELECT id, name, path, platform FROM applications ORDER BY name COLLATE NOCASE")
        .map_err(|error| format!("Could not read the application catalog: {error}"))?;
    let applications = statement
        .query_map([], |row| {
            Ok(NativeApplication {
                id: row.get(0)?,
                name: row.get(1)?,
                path: row.get(2)?,
                platform: row.get(3)?,
            })
        })
        .map_err(|error| format!("Could not query the application catalog: {error}"))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("Could not decode the application catalog: {error}"))?;
    Ok(applications
        .into_iter()
        .map(|application| IndexedApplication::new(application, &usage))
        .collect())
}

fn load_usage(connection: &Connection) -> Result<HashMap<String, (u32, Option<i64>)>, String> {
    let mut statement = connection
        .prepare("SELECT application_id, launch_count, last_launched_at FROM application_usage")
        .map_err(|error| format!("Could not read application usage: {error}"))?;
    let usage = statement
        .query_map([], |row| Ok((row.get(0)?, (row.get(1)?, row.get(2)?))))
        .map_err(|error| format!("Could not query application usage: {error}"))?
        .collect::<Result<HashMap<_, _>, _>>()
        .map_err(|error| format!("Could not decode application usage: {error}"))?;
    Ok(usage)
}

#[derive(Deserialize)]
struct ApplicationAliases {
    names: Vec<String>,
    aliases: Vec<String>,
}

fn common_application_aliases(name: &str) -> Vec<String> {
    static CATALOG: OnceLock<HashMap<String, Vec<String>>> = OnceLock::new();
    CATALOG
        .get_or_init(|| {
            let entries: Vec<ApplicationAliases> = serde_json::from_str(include_str!(
                "../../../../packages/command-core/src/application-aliases.json"
            ))
            .expect("valid bundled application alias catalog");
            entries
                .into_iter()
                .flat_map(|entry| {
                    let aliases: Vec<String> =
                        entry.aliases.iter().map(|alias| normalize(alias)).collect();
                    entry
                        .names
                        .into_iter()
                        .map(move |name| (normalize(&name), aliases.clone()))
                })
                .collect()
        })
        .get(&normalize(name))
        .cloned()
        .unwrap_or_default()
}

fn normalize(value: &str) -> String {
    value
        .nfkd()
        .filter(|character| !is_combining_mark(*character))
        .flat_map(char::to_lowercase)
        .collect::<String>()
        .nfc()
        .collect()
}

fn matches_character(needle: char, candidate: char) -> bool {
    if needle == candidate {
        return true;
    }
    let initial = needle as u32;
    let syllable = candidate as u32;
    (0x1100..=0x1112).contains(&initial)
        && (0xac00..=0xd7a3).contains(&syllable)
        && (syllable - 0xac00) / 588 == initial - 0x1100
}

// Keep tiers and bounded within-tier bonuses aligned with command-core/search.ts.
fn match_score(needle: &str, value: &str, tiers: [u32; 3]) -> Option<f64> {
    let tier = if needle == value {
        tiers[0]
    } else if value.starts_with(needle) {
        tiers[1]
    } else {
        tiers[2]
    };
    let haystack = value.chars().collect::<Vec<_>>();
    let mut cursor = 0usize;
    let mut score = 0.0;
    let mut streak = 0usize;
    for character in needle.chars() {
        let relative = haystack[cursor..]
            .iter()
            .position(|candidate| matches_character(character, *candidate))?;
        let index = cursor + relative;
        let boundary = index == 0
            || haystack[index - 1].is_whitespace()
            || matches!(haystack[index - 1], '_' | '-' | '.' | '/');
        streak = if index == cursor { streak + 1 } else { 0 };
        score +=
            14.0 + streak as f64 * 5.0 + if boundary { 12.0 } else { 0.0 } - relative.min(9) as f64;
        cursor = index + 1;
    }
    score -= haystack.len().saturating_sub(needle.chars().count()) as f64 * 0.08;
    Some(tier as f64 * 1_000_000.0 + 10_000.0 + score.clamp(-10_000.0, 10_000.0))
}

fn frecency_bonus(launch_count: u32, last_launched_at: Option<i64>, now: i64) -> f64 {
    let frequency = (launch_count as f64 + 1.0).ln() * 8.0;
    let recency = last_launched_at
        .map(|timestamp| now.saturating_sub(timestamp))
        .map(|age| match age {
            0..=3_600 => 44.0,
            3_601..=86_400 => 30.0,
            86_401..=604_800 => 18.0,
            604_801..=2_592_000 => 8.0,
            _ => 0.0,
        })
        .unwrap_or_default();
    (frequency + recency).min(72.0)
}

fn unix_timestamp() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_index(applications: Vec<NativeApplication>) -> ApplicationIndex {
        let database = Connection::open_in_memory().expect("open in-memory database");
        initialize_database(&database).expect("initialize database");
        let usage = HashMap::new();
        ApplicationIndex {
            inner: Arc::new(ApplicationIndexInner {
                applications: RwLock::new(
                    applications
                        .into_iter()
                        .map(|application| IndexedApplication::new(application, &usage))
                        .collect(),
                ),
                database: Mutex::new(database),
            }),
        }
    }

    fn application(id: &str, name: &str) -> NativeApplication {
        NativeApplication {
            id: id.to_string(),
            name: name.to_string(),
            path: format!("/Applications/{name}.app"),
            platform: "macos".to_string(),
        }
    }

    #[test]
    fn exact_and_prefix_matches_beat_loose_subsequences() {
        let index = test_index(vec![
            application("visual", "Visual Studio Code"),
            application("code", "Code"),
            application("xcode", "Xcode"),
        ]);
        let results = index.search("code", 10);
        assert_eq!(results[0].id, "code");
        assert_eq!(results[1].id, "visual");
        assert_eq!(results[2].id, "xcode");
    }

    #[test]
    fn successful_usage_immediately_changes_empty_query_order() {
        let index = test_index(vec![
            application("alpha", "Alpha"),
            application("beta", "Beta"),
        ]);
        index.record_launch("beta").expect("record usage");
        let results = index.search("", 10);
        assert_eq!(results[0].id, "beta");
        assert!(results[0].ranking_boost > 0.0);
    }

    #[test]
    fn search_result_limit_is_bounded() {
        let applications = (0..150)
            .map(|index| application(&format!("app-{index}"), &format!("App {index}")))
            .collect();
        assert_eq!(
            test_index(applications).search("app", 1_000).len(),
            MAX_SEARCH_RESULTS
        );
    }

    #[test]
    fn common_aliases_retrieve_installed_apps_before_the_candidate_limit() {
        let mut apps: Vec<_> = (0..60)
            .map(|i| application(&format!("weak-{i}"), &format!("크롬 도구 {i}")))
            .collect();
        apps.push(application("chrome", "Google Chrome"));
        apps.push(application("helper", "Google Chrome Helper"));
        let index = test_index(apps);
        for query in [
            "크롬",
            "ㅋㄹ",
            "크ㄹ",
            "구글 ㅋㄹ",
            "google 크롬",
            "google ㅋㄹ",
        ] {
            let results = index.search(query, 40);
            assert!(
                results.iter().any(|result| result.id == "chrome"),
                "{query}"
            );
            assert!(
                !results.iter().any(|result| result.id == "helper"),
                "{query}"
            );
        }
        assert_eq!(index.search("크롬", 40)[0].id, "chrome");
        let decomposed: String = "크롬".nfd().collect();
        assert_eq!(index.search(&decomposed, 40)[0].id, "chrome");
    }

    #[test]
    fn unicode_and_mixed_initials_match_without_splitting_full_syllables() {
        let index = test_index(vec![
            application("ko", "한글 메모"),
            application("cafe", "Café 🚀 Notes"),
        ]);
        for query in ["ㅎㄱ ㅁㅁ", "한ㄱ 메ㅁ"] {
            assert_eq!(index.search(query, 40)[0].id, "ko");
        }
        assert!(index.search("하글", 40).is_empty());
        assert!(index.search("ㅏ", 40).is_empty());
        for query in ["cafe 🚀", "Ｃａｆｅ", "🚀n"] {
            assert_eq!(index.search(query, 40)[0].id, "cafe");
        }
    }

    #[test]
    fn bounded_frecency_cannot_promote_prefixes_over_exact_titles_or_aliases() {
        let index = test_index(vec![
            application("prefix", "크롬 도구"),
            application("chrome", "Google Chrome"),
        ]);
        {
            let mut apps = index.inner.applications.write().unwrap();
            apps[0].launch_count = u32::MAX;
            apps[0].last_launched_at = Some(unix_timestamp());
        }
        assert_eq!(index.search("크롬", 1)[0].id, "chrome");
        assert_eq!(
            frecency_bonus(u32::MAX, Some(unix_timestamp()), unix_timestamp()),
            72.0
        );
        assert!(index.search("unrelated", 40).is_empty());
    }

    #[test]
    fn lookup_returns_only_the_exact_indexed_application() {
        let index = test_index(vec![
            application("code", "Code"),
            application("xcode", "Xcode"),
        ]);

        let result = index.lookup("code").expect("find exact application");
        assert_eq!(result.id, "code");
        assert_eq!(result.name, "Code");
        assert_eq!(result.path, "/Applications/Code.app");
        assert_eq!(result.platform, "macos");
        assert_eq!(result.ranking_boost, 0.0);
        assert!(index.lookup("Code").is_none());
        assert!(index.lookup("missing").is_none());
    }
}

//! HelperNext — the QQ Music online source's data component.
//!
//! One JSON request per line on stdin, one JSON reply per line on stdout. The
//! protocol is byte-for-byte the one the Python helper this replaces spoke, so
//! the app's process client needs no changes and unported methods can keep being
//! served by the old binary while the migration is in flight.
//!
//! Why it exists (the user's brief): the Python helper bundled a whole
//! interpreter and a third-party library to talk to a handful of HTTP endpoints,
//! and it was ~56 MB of runtime for that. This component is one statically
//! linked binary with the endpoints, the credential, the rate limit and the
//! circuit breaker inside it, so an upstream change is a binary swap and never an
//! app rebuild.
//!
//! stdout is reserved for protocol JSON; diagnostics go to stderr.

mod credential;
mod guard;
mod methods;
mod upstream;

use credential::CredentialStore;
use guard::Class;
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::sync::Arc;

fn log(message: &str) {
    eprintln!("[qqmusic-helper-next] {message}");
}

/// Where the credential lives.
///
/// The app prefers the external helper directory over the copy inside the app
/// bundle, exactly as it did for the Python helper — same directory, same file,
/// so an existing login survives the swap and the old helper can be brought back
/// without logging in again.
fn helper_directory() -> PathBuf {
    if let Ok(explicit) = std::env::var("QQMUSIC_HELPER_DIR") {
        if !explicit.is_empty() {
            return PathBuf::from(explicit);
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join("Library/Application Support/kmgccc.player/QQMusicHelper")
}

fn main() {
    let store = Arc::new(CredentialStore::for_directory(&helper_directory()));
    let upstream = Arc::new(upstream::Upstream::new());

    log(&format!(
        "version={} protocol={} credential={}",
        methods::COMPONENT_VERSION,
        methods::PROTOCOL_VERSION,
        store.path().display()
    ));

    let stdin = std::io::stdin();
    let mut workers = Vec::new();

    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let request: Value = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(error) => {
                // No id to echo, but the app still deserves an answer rather than
                // a hung request.
                emit(json!({ "ok": false, "error": format!("请求不是合法 JSON：{error}") }));
                continue;
            }
        };

        // One thread per request: the app issues a handful of reads at a time and
        // they must not queue behind each other. The rate limiter and the breaker
        // are shared, so concurrency is bounded at the upstream, not here.
        let store = Arc::clone(&store);
        let upstream = Arc::clone(&upstream);
        workers.retain(|worker: &std::thread::JoinHandle<()>| !worker.is_finished());
        workers.push(std::thread::spawn(move || {
            let response = serve(&upstream, &store, &request);
            emit(response);
        }));
    }

    for worker in workers {
        let _ = worker.join();
    }
}

fn serve(upstream: &upstream::Upstream, store: &CredentialStore, request: &Value) -> Value {
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let method = request.get("method").and_then(Value::as_str).unwrap_or("");
    let params = request.get("params").cloned().unwrap_or(json!({}));

    if method == "get_helper_info" {
        // Answered from the component's own state: the app asks this before
        // anything else and it must not depend on the network.
        let value = methods::dispatch(upstream, None, method, &params)
            .unwrap_or_else(|error| json!({ "error": error.to_string() }));
        return with_id(id, value);
    }
    if method.is_empty() || !methods::is_known(method) {
        return with_id(
            id,
            json!({ "ok": false, "error": format!("不支持的方法：{method}") }),
        );
    }

    if method == "import_cookies" {
        return match methods::credential_from_params(&params) {
            Ok(credential) => match store.store(&credential) {
                Ok(()) => with_id(id, json!({ "login": { "loggedIn": true } })),
                Err(error) => with_id(id, json!({ "ok": false, "error": format!("写入凭据失败：{error}") })),
            },
            Err(error) => with_id(id, json!({ "ok": false, "error": error.to_string() })),
        };
    }
    if method == "logout" {
        let _ = store.clear();
        return with_id(id, json!({ "login": { "loggedIn": false } }));
    }

    let credential = store.load();
    let started = std::time::Instant::now();
    let result = methods::dispatch(upstream, credential.as_ref(), method, &params);
    let duration_ms = started.elapsed().as_millis();
    log(&format!("method={method} durationMs={duration_ms}"));

    match result {
        Ok(value) => with_id(id, value),
        Err(error) => with_id(id, json!({ "ok": false, "error": error.to_string() })),
    }
}

/// Attach `ok: true` and the request id.
///
/// The id is not decoration: the app matches a reply to its request by it, so a
/// response without one is waited on until the app's 15-second timeout. (The
/// Python helper learned this the hard way — one new method shipped without it.)
fn with_id(id: Value, mut value: Value) -> Value {
    if let Some(object) = value.as_object_mut() {
        object.insert("id".into(), id);
        object.entry("ok").or_insert(json!(true));
        value
    } else {
        json!({ "id": id, "ok": true, "value": value })
    }
}

/// Serialize one reply to stdout under a lock, so two threads cannot interleave
/// within a line.
fn emit(value: Value) {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard = LOCK.lock().expect("stdout");
    let line = serde_json::to_string(&value).unwrap_or_else(|_| "{\"ok\":false}".into());
    let stdout = std::io::stdout();
    let mut handle = stdout.lock();
    let _ = writeln!(handle, "{line}");
    let _ = handle.flush();
}

/// `Class` is used by the method layer; re-exported here so the audit of "what
/// throttles what" is one file away from the entry point.
#[allow(dead_code)]
fn throttled_classes() -> [Class; 5] {
    [
        Class::Read,
        Class::Interactive,
        Class::Playback,
        Class::Account,
        Class::Write,
    ]
}

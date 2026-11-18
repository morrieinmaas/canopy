use std::collections::HashMap;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use opensessions_runtime::agent_watchers::{
    AgentWatcherSnapshot, ClaudeCodeParseState, claude_code_fold_chunk,
    claude_code_snapshot_from_state, decode_claude_project_dir,
};

use super::{AGENT_WATCHER_RECENT_MS, debug_log, file_mtime_ms, metadata_mtime_ms};

#[derive(Debug, Default)]
struct ClaudeScanEntry {
    dev: u64,
    ino: u64,
    seen_len: u64,
    offset: u64,
    state: ClaudeCodeParseState,
}

/// Per-file parse progress kept across watcher ticks, keyed by transcript path.
#[derive(Debug, Default)]
pub(crate) struct ClaudeScanCache {
    entries: HashMap<PathBuf, ClaudeScanEntry>,
    bytes_read_last_scan: u64,
}

impl ClaudeScanCache {
    #[cfg(test)]
    fn bytes_read_last_scan(&self) -> u64 {
        self.bytes_read_last_scan
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.entries.len()
    }
}

/// The unread part of a transcript and the offset it starts at.
struct ClaudeTail {
    start: u64,
    bytes: Vec<u8>,
}

/// True when the byte just before `offset` is a newline, i.e. the cached offset
/// still sits on a line boundary of the file behind this handle.
fn newline_before(file: &mut fs::File, offset: u64) -> std::io::Result<bool> {
    let mut byte = [0u8; 1];
    file.seek(SeekFrom::Start(offset - 1))?;
    Ok(file.read(&mut byte)? == 1 && byte[0] == b'\n')
}

/// Reads from `offset` to the end, or from the start when the file was rewritten
/// in place and no longer has a line boundary at `offset`.
fn read_claude_tail(file: &mut fs::File, offset: u64) -> std::io::Result<ClaudeTail> {
    let start = if offset > 0 && newline_before(file, offset)? {
        offset
    } else {
        0
    };
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(ClaudeTail { start, bytes })
}

/// Folds the complete lines not yet seen into the entry and returns the bytes
/// read. On error the entry is left untouched; the caller keeps it cached so
/// the next tick retries from the same offset.
fn advance_claude_entry(entry: &mut ClaudeScanEntry, file: &mut fs::File) -> std::io::Result<u64> {
    let tail = read_claude_tail(file, entry.offset)?;
    if tail.start == 0 {
        entry.state = ClaudeCodeParseState::default();
    }
    let chunk = String::from_utf8_lossy(&tail.bytes);
    let state = std::mem::take(&mut entry.state);
    entry.state = claude_code_fold_chunk(state, &chunk).0;
    // Lossy conversion can change the length of invalid bytes, so measure the
    // consumed prefix in the original bytes.
    let consumed_bytes = tail
        .bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |index| index + 1);
    let read = tail.bytes.len() as u64;
    entry.offset = tail.start + consumed_bytes as u64;
    entry.seen_len = tail.start + read;
    Ok(read)
}

fn claude_entry_for(
    cache: &mut ClaudeScanCache,
    path: &Path,
    meta: &fs::Metadata,
) -> ClaudeScanEntry {
    match cache.entries.remove(path) {
        Some(entry)
            if entry.dev == meta.dev()
                && entry.ino == meta.ino()
                && entry.seen_len <= meta.len()
                && entry.offset <= meta.len() =>
        {
            entry
        }
        _ => ClaudeScanEntry {
            dev: meta.dev(),
            ino: meta.ino(),
            ..ClaudeScanEntry::default()
        },
    }
}

fn claude_transcript_paths(home: &Path) -> Vec<(PathBuf, String)> {
    let Ok(projects) = fs::read_dir(home.join(".claude/projects")) else {
        return Vec::new();
    };
    projects
        .flatten()
        .filter(|project| project.path().is_dir())
        .flat_map(|project| {
            let encoded = project.file_name().to_string_lossy().to_string();
            let project_dir = decode_claude_project_dir(&encoded, |path| Path::new(path).is_dir());
            fs::read_dir(project.path())
                .into_iter()
                .flatten()
                .flatten()
                .map(|file| file.path())
                .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("jsonl"))
                .map(|path| (path, project_dir.clone()))
                .collect::<Vec<_>>()
        })
        .collect()
}

fn log_claude_io_error<T>(path: &Path, action: &str, result: std::io::Result<T>) -> Option<T> {
    result
        .map_err(|err| {
            debug_log(format!(
                "claude transcript {action} failed for {}: {err}",
                path.display()
            ))
        })
        .ok()
}

struct ClaudeTranscriptScan {
    entry: ClaudeScanEntry,
    mtime_ms: u64,
    bytes_read: u64,
}

enum ClaudeTranscriptOutcome {
    /// Gone or outside the recent window: the cached entry is dropped.
    Skipped,
    /// Recent but unreadable right now: the cached entry is kept for the next tick.
    Failed,
    Scanned(ClaudeTranscriptScan),
}

fn in_recent_window(mtime_ms: u64, now_ms: u64) -> bool {
    now_ms.saturating_sub(mtime_ms) <= AGENT_WATCHER_RECENT_MS
}

/// Scans one transcript through a single handle, so identity, length and mtime
/// all describe the same file the bytes are read from. The path is statted
/// first so files outside the recent window are never opened.
fn scan_claude_transcript(
    previous: &mut ClaudeScanCache,
    path: &Path,
    now_ms: u64,
) -> ClaudeTranscriptOutcome {
    if !file_mtime_ms(path).is_some_and(|mtime_ms| in_recent_window(mtime_ms, now_ms)) {
        return ClaudeTranscriptOutcome::Skipped;
    }
    let Some(mut file) = log_claude_io_error(path, "open", fs::File::open(path)) else {
        return ClaudeTranscriptOutcome::Failed;
    };
    let Some(meta) = log_claude_io_error(path, "stat", file.metadata()) else {
        return ClaudeTranscriptOutcome::Failed;
    };
    let Some(mtime_ms) = metadata_mtime_ms(&meta).filter(|ms| in_recent_window(*ms, now_ms)) else {
        return ClaudeTranscriptOutcome::Skipped;
    };
    let mut entry = claude_entry_for(previous, path, &meta);
    if entry.seen_len == meta.len() {
        return ClaudeTranscriptOutcome::Scanned(ClaudeTranscriptScan {
            entry,
            mtime_ms,
            bytes_read: 0,
        });
    }
    match log_claude_io_error(path, "read", advance_claude_entry(&mut entry, &mut file)) {
        Some(bytes_read) => ClaudeTranscriptOutcome::Scanned(ClaudeTranscriptScan {
            entry,
            mtime_ms,
            bytes_read,
        }),
        None => {
            // The failed read left the entry untouched; put it back for the next tick.
            previous.entries.insert(path.to_path_buf(), entry);
            ClaudeTranscriptOutcome::Failed
        }
    }
}

pub(crate) fn scan_claude_code_projects_cached(
    home: &Path,
    now_ms: u64,
    cache: &mut ClaudeScanCache,
    snapshots: &mut Vec<AgentWatcherSnapshot>,
) {
    let mut previous = std::mem::take(cache);
    let mut bytes_read = 0;

    for (path, project_dir) in claude_transcript_paths(home) {
        let Some(thread_id) = path.file_stem().and_then(|stem| stem.to_str()) else {
            continue;
        };
        match scan_claude_transcript(&mut previous, &path, now_ms) {
            ClaudeTranscriptOutcome::Skipped => {}
            ClaudeTranscriptOutcome::Failed => {
                if let Some(entry) = previous.entries.remove(&path) {
                    cache.entries.insert(path, entry);
                }
            }
            ClaudeTranscriptOutcome::Scanned(scan) => {
                bytes_read += scan.bytes_read;
                if let Some(snapshot) = claude_code_snapshot_from_state(
                    thread_id,
                    &project_dir,
                    &scan.entry.state,
                    scan.mtime_ms,
                    now_ms,
                ) {
                    snapshots.push(snapshot);
                }
                cache.entries.insert(path, scan.entry);
            }
        }
    }
    cache.bytes_read_last_scan = bytes_read;
}

#[cfg(test)]
mod claude_scan_cache_tests {
    use super::*;
    use opensessions_runtime::protocol::AgentStatus;
    use std::io::Write;
    use std::time::SystemTime;

    fn now_ms() -> u64 {
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64
    }

    fn temp_home(tag: &str) -> PathBuf {
        let home = std::env::temp_dir().join(format!(
            "opensessions-claude-scan-{tag}-{}-{}",
            std::process::id(),
            now_ms()
        ));
        fs::create_dir_all(home.join(".claude/projects/-tmp-proj")).unwrap();
        home
    }

    fn transcript(home: &Path, id: &str) -> PathBuf {
        home.join(format!(".claude/projects/-tmp-proj/{id}.jsonl"))
    }

    fn user_line(text: &str) -> String {
        format!(
            "{{\"type\":\"user\",\"message\":{{\"role\":\"user\",\"content\":[{{\"type\":\"text\",\"text\":\"{text}\"}}]}}}}\n"
        )
    }

    fn assistant_done_line() -> String {
        "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Done\"}],\"stop_reason\":\"end_turn\"}}\n".to_string()
    }

    fn append(path: &Path, text: &str) {
        let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
        file.write_all(text.as_bytes()).unwrap();
    }

    fn scan(home: &Path, cache: &mut ClaudeScanCache) -> Vec<AgentWatcherSnapshot> {
        let mut snapshots = Vec::new();
        scan_claude_code_projects_cached(home, now_ms(), cache, &mut snapshots);
        snapshots
    }

    #[test]
    fn first_scan_reads_whole_file_and_returns_snapshot() {
        let home = temp_home("first");
        let body = format!("{}{}", user_line("Implement auth"), assistant_done_line());
        fs::write(transcript(&home, "a"), &body).unwrap();
        let mut cache = ClaudeScanCache::default();

        let snapshots = scan(&home, &mut cache);

        assert_eq!(snapshots.len(), 1);
        assert_eq!(snapshots[0].thread_id.as_deref(), Some("a"));
        assert_eq!(snapshots[0].thread_name.as_deref(), Some("Implement auth"));
        assert_eq!(snapshots[0].status, AgentStatus::Done);
        assert_eq!(cache.bytes_read_last_scan(), body.len() as u64);
        assert_eq!(cache.len(), 1);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn unchanged_file_is_not_read_again() {
        let home = temp_home("unchanged");
        fs::write(transcript(&home, "a"), user_line("Implement auth")).unwrap();
        let mut cache = ClaudeScanCache::default();
        let first = scan(&home, &mut cache);
        assert!(cache.bytes_read_last_scan() > 0);

        let second = scan(&home, &mut cache);

        assert_eq!(cache.bytes_read_last_scan(), 0);
        assert_eq!(second.len(), 1);
        assert_eq!(second[0].thread_name, first[0].thread_name);
        assert_eq!(second[0].last_user_prompt, first[0].last_user_prompt);
        assert_eq!(second[0].status, first[0].status);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn appended_lines_update_status_reading_only_new_bytes() {
        let home = temp_home("append");
        let path = transcript(&home, "a");
        fs::write(&path, user_line("Implement auth")).unwrap();
        let mut cache = ClaudeScanCache::default();
        let first = scan(&home, &mut cache);
        assert_eq!(first[0].status, AgentStatus::Running);

        let added = assistant_done_line();
        append(&path, &added);
        let second = scan(&home, &mut cache);

        assert_eq!(second.len(), 1);
        assert_eq!(second[0].status, AgentStatus::Done);
        assert_eq!(second[0].thread_name.as_deref(), Some("Implement auth"));
        assert_eq!(cache.bytes_read_last_scan(), added.len() as u64);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn partial_trailing_line_is_left_for_the_next_tick() {
        let home = temp_home("partial");
        let path = transcript(&home, "a");
        let complete = user_line("First");
        let second = user_line("Second");
        let (head, tail) = second.split_at(20);
        fs::write(&path, format!("{complete}{head}")).unwrap();
        let mut cache = ClaudeScanCache::default();

        let snapshots = scan(&home, &mut cache);
        assert_eq!(snapshots[0].last_user_prompt.as_deref(), Some("First"));

        append(&path, tail);
        let snapshots = scan(&home, &mut cache);
        assert_eq!(snapshots[0].last_user_prompt.as_deref(), Some("Second"));
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn truncated_file_is_reread_from_the_start() {
        let home = temp_home("truncate");
        let path = transcript(&home, "a");
        fs::write(
            &path,
            format!(
                "{}{}{}",
                user_line("Old task"),
                assistant_done_line(),
                user_line("Old follow up")
            ),
        )
        .unwrap();
        let mut cache = ClaudeScanCache::default();
        scan(&home, &mut cache);

        let fresh = user_line("New");
        fs::write(&path, &fresh).unwrap();
        let snapshots = scan(&home, &mut cache);

        assert_eq!(snapshots.len(), 1);
        assert_eq!(snapshots[0].thread_name.as_deref(), Some("New"));
        assert_eq!(snapshots[0].last_user_prompt.as_deref(), Some("New"));
        assert_eq!(cache.bytes_read_last_scan(), fresh.len() as u64);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn replaced_file_with_new_identity_is_reread_from_the_start() {
        let home = temp_home("replace");
        let path = transcript(&home, "a");
        fs::write(&path, user_line("Old task")).unwrap();
        let mut cache = ClaudeScanCache::default();
        scan(&home, &mut cache);

        let replacement = format!("{}{}", user_line("Replacement task"), assistant_done_line());
        let staged = home.join("staged.jsonl");
        fs::write(&staged, &replacement).unwrap();
        fs::rename(&staged, &path).unwrap();
        let snapshots = scan(&home, &mut cache);

        assert_eq!(snapshots.len(), 1);
        assert_eq!(
            snapshots[0].thread_name.as_deref(),
            Some("Replacement task")
        );
        assert_eq!(snapshots[0].status, AgentStatus::Done);
        assert_eq!(cache.bytes_read_last_scan(), replacement.len() as u64);
        fs::remove_dir_all(&home).ok();
    }

    fn set_mode(path: &Path, mode: u32) {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
    }

    /// Root ignores file modes, so a chmod-based failure cannot be provoked.
    fn modes_are_enforced(path: &Path) -> bool {
        set_mode(path, 0o000);
        let enforced = fs::File::open(path).is_err();
        set_mode(path, 0o644);
        enforced
    }

    #[test]
    fn unreadable_file_keeps_its_cached_offset_for_the_next_tick() {
        let home = temp_home("keep-offset");
        let path = transcript(&home, "a");
        let first = user_line("Implement auth");
        fs::write(&path, &first).unwrap();
        if !modes_are_enforced(&path) {
            fs::remove_dir_all(&home).ok();
            return;
        }
        let mut cache = ClaudeScanCache::default();
        scan(&home, &mut cache);
        let cached_offset = first.len() as u64;
        assert_eq!(cache.entries[&path].offset, cached_offset);

        set_mode(&path, 0o000);
        let snapshots = scan(&home, &mut cache);
        assert!(snapshots.is_empty());
        assert_eq!(cache.entries[&path].offset, cached_offset);

        set_mode(&path, 0o644);
        let added = assistant_done_line();
        append(&path, &added);
        let snapshots = scan(&home, &mut cache);

        assert_eq!(snapshots[0].status, AgentStatus::Done);
        assert_eq!(cache.bytes_read_last_scan(), added.len() as u64);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn failed_read_keeps_the_cached_entry_unchanged() {
        let home = temp_home("readerr");
        // A directory opens fine but fails on read, whatever the user is.
        let path = transcript(&home, "a");
        fs::create_dir(&path).unwrap();
        let meta = fs::metadata(&path).unwrap();
        if meta.len() < 2 {
            fs::remove_dir_all(&home).ok();
            return;
        }
        // Strictly below the directory length, so the entry stays valid and a read is attempted.
        let cached = meta.len() - 1;
        let mut cache = ClaudeScanCache::default();
        cache.entries.insert(
            path.clone(),
            ClaudeScanEntry {
                dev: meta.dev(),
                ino: meta.ino(),
                seen_len: cached,
                offset: cached,
                state: ClaudeCodeParseState::default(),
            },
        );

        let snapshots = scan(&home, &mut cache);

        assert!(snapshots.is_empty());
        assert_eq!(cache.len(), 1);
        assert_eq!(cache.entries[&path].offset, cached);
        assert_eq!(cache.entries[&path].seen_len, cached);
        assert_eq!(cache.bytes_read_last_scan(), 0);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn entries_for_files_outside_the_recent_window_are_dropped() {
        let home = temp_home("evict");
        let path = transcript(&home, "a");
        fs::write(&path, user_line("Implement auth")).unwrap();
        let mut cache = ClaudeScanCache::default();
        let mut snapshots = Vec::new();
        scan_claude_code_projects_cached(&home, now_ms(), &mut cache, &mut snapshots);
        assert_eq!(cache.len(), 1);

        let later = now_ms() + AGENT_WATCHER_RECENT_MS + 60_000;
        let mut snapshots = Vec::new();
        scan_claude_code_projects_cached(&home, later, &mut cache, &mut snapshots);

        assert!(snapshots.is_empty());
        assert_eq!(cache.len(), 0);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn entries_for_deleted_files_are_dropped() {
        let home = temp_home("deleted");
        fs::write(transcript(&home, "a"), user_line("One")).unwrap();
        fs::write(transcript(&home, "b"), user_line("Two")).unwrap();
        let mut cache = ClaudeScanCache::default();
        scan(&home, &mut cache);
        assert_eq!(cache.len(), 2);

        fs::remove_file(transcript(&home, "a")).unwrap();
        let snapshots = scan(&home, &mut cache);

        assert_eq!(snapshots.len(), 1);
        assert_eq!(cache.len(), 1);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn unreadable_file_is_retried_on_the_next_scan() {
        let home = temp_home("unreadable");
        let path = transcript(&home, "a");
        fs::write(&path, user_line("Implement auth")).unwrap();
        if !modes_are_enforced(&path) {
            fs::remove_dir_all(&home).ok();
            return;
        }
        set_mode(&path, 0o000);
        let mut cache = ClaudeScanCache::default();

        let blocked = scan(&home, &mut cache);
        set_mode(&path, 0o644);
        let retried = scan(&home, &mut cache);

        assert!(blocked.is_empty());
        assert_eq!(retried.len(), 1);
        assert_eq!(retried[0].thread_name.as_deref(), Some("Implement auth"));
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn rewrite_shorter_than_the_observed_end_is_reread() {
        let home = temp_home("short-rewrite");
        let path = transcript(&home, "a");
        let second = user_line("Second");
        let first = user_line("Old");
        fs::write(&path, format!("{first}{}", &second[..20])).unwrap();
        let mut cache = ClaudeScanCache::default();
        scan(&home, &mut cache);

        let fresh = user_line("New");
        assert!(fresh.len() >= first.len() && fresh.len() < first.len() + 20);
        fs::write(&path, &fresh).unwrap();
        let snapshots = scan(&home, &mut cache);

        assert_eq!(snapshots[0].thread_name.as_deref(), Some("New"));
        assert_eq!(cache.bytes_read_last_scan(), fresh.len() as u64);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn in_place_rewrite_to_larger_content_is_reread_from_the_start() {
        let home = temp_home("inplace");
        let path = transcript(&home, "a");
        fs::write(
            &path,
            format!("{}{}", user_line("Old task"), assistant_done_line()),
        )
        .unwrap();
        let mut cache = ClaudeScanCache::default();
        scan(&home, &mut cache);

        let rewritten = format!(
            "{}{}{}",
            user_line("Brand new and much longer task"),
            assistant_done_line(),
            user_line("Third")
        );
        let mut file = fs::OpenOptions::new().write(true).open(&path).unwrap();
        file.write_all(rewritten.as_bytes()).unwrap();
        drop(file);
        let snapshots = scan(&home, &mut cache);

        assert_eq!(
            snapshots[0].thread_name.as_deref(),
            Some("Brand new and much longer task")
        );
        assert_eq!(snapshots[0].last_user_prompt.as_deref(), Some("Third"));
        assert_eq!(cache.bytes_read_last_scan(), rewritten.len() as u64);
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn line_split_inside_a_multibyte_char_is_read_exactly() {
        let home = temp_home("multibyte");
        let path = transcript(&home, "a");
        let line = user_line("\u{65e5}\u{672c}");
        let split = line.find('\u{65e5}').unwrap() + 1;
        let (head, tail) = line.as_bytes().split_at(split);
        let mut body = user_line("First").into_bytes();
        body.extend_from_slice(head);
        fs::write(&path, body).unwrap();
        let mut cache = ClaudeScanCache::default();
        let snapshots = scan(&home, &mut cache);
        assert_eq!(snapshots[0].last_user_prompt.as_deref(), Some("First"));

        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(tail).unwrap();
        drop(file);
        let snapshots = scan(&home, &mut cache);

        assert_eq!(
            snapshots[0].last_user_prompt.as_deref(),
            Some("\u{65e5}\u{672c}")
        );
        fs::remove_dir_all(&home).ok();
    }
}

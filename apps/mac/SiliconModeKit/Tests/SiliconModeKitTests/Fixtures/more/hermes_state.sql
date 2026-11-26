-- Synthetic Hermes state.db (schema v16 subset). Times are epoch seconds around 2026-11-20T10:00Z (1795168800).
PRAGMA journal_mode=WAL;
CREATE TABLE sessions (
    id TEXT PRIMARY KEY, source TEXT NOT NULL, user_id TEXT, model TEXT, model_config TEXT, system_prompt TEXT,
    parent_session_id TEXT, started_at REAL NOT NULL, ended_at REAL, end_reason TEXT, message_count INTEGER DEFAULT 0,
    tool_call_count INTEGER DEFAULT 0, cwd TEXT, git_branch TEXT, title TEXT, archived INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT, tool_call_id TEXT,
    tool_calls TEXT, tool_name TEXT, timestamp REAL NOT NULL, token_count INTEGER, finish_reason TEXT,
    active INTEGER NOT NULL DEFAULT 1, compacted INTEGER NOT NULL DEFAULT 0
);
-- 1. Live CLI session, waiting on a tool call (no result yet).
INSERT INTO sessions(id, source, model, started_at, cwd, title) VALUES ('tui_live_1', 'tui', 'demo-model-1', 1795168700, '/tmp/demo-proj', 'Refactor the demo parser');
INSERT INTO messages(session_id, role, content, timestamp) VALUES ('tui_live_1', 'user', 'Please refactor the demo parser', 1795168710);
INSERT INTO messages(session_id, role, content, tool_calls, timestamp, finish_reason) VALUES ('tui_live_1', 'assistant', NULL,
  '[{"id":"call_a1","type":"function","function":{"name":"terminal","arguments":"{\"command\":\"swift test\"}"}}]', 1795168720, 'tool_calls');
-- 2. Stale TUI session (not ended, no process) → dropped.
INSERT INTO sessions(id, source, started_at, cwd) VALUES ('tui_stale_2', 'tui', 1794000000, '/tmp/old');
-- 3. Cron session that ended 5 minutes ago → finished.
INSERT INTO sessions(id, source, model, started_at, ended_at, end_reason, title) VALUES ('cron_done_3', 'cron', 'demo-model-2', 1795168600, 1795168800, 'cron_complete', 'Nightly digest');
INSERT INTO messages(session_id, role, content, timestamp) VALUES ('cron_done_3', 'user', 'Run the nightly digest', 1795168610);
INSERT INTO messages(session_id, role, content, timestamp, finish_reason) VALUES ('cron_done_3', 'assistant', 'Digest sent.', 1795168790, 'stop');
-- 4. Archived session → ignored.
INSERT INTO sessions(id, source, started_at, cwd, archived) VALUES ('tui_archived_4', 'tui', 1795168750, '/tmp/demo-proj', 1);

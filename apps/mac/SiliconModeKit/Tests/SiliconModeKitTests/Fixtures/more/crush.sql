-- Synthetic Crush crush.db (subset). Times are unix seconds.
CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, title TEXT, message_count INTEGER, updated_at INTEGER, created_at INTEGER);
CREATE TABLE messages (id TEXT PRIMARY KEY, session_id TEXT, role TEXT, parts TEXT, model TEXT, created_at INTEGER, updated_at INTEGER, finished_at INTEGER);
INSERT INTO sessions VALUES ('cr-1', NULL, 'Demo crush session', 3, 1795168730, 1795168700);
INSERT INTO sessions VALUES ('cr-child', 'cr-1', 'Sub task', 1, 1795168790, 1795168790);
INSERT INTO messages VALUES ('a', 'cr-1', 'user', '[{"type":"text","data":{"text":"Delete the temp files"}}]', NULL, 1795168700, 1795168700, 1795168700);
INSERT INTO messages VALUES ('b', 'cr-1', 'assistant', '[{"type":"text","data":{"text":"Removing them."}},{"type":"tool_call","data":{"id":"call-1","name":"bash","input":"{\"command\":\"rm -rf tmp\"}"}}]', 'demo-model', 1795168710, 1795168710, 1795168711);

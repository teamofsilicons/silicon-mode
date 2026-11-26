-- Synthetic Goose sessions.db (subset).
CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT, description TEXT, working_dir TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE messages (id INTEGER PRIMARY KEY, message_id TEXT, session_id TEXT, role TEXT, content_json TEXT, created_timestamp INTEGER);
INSERT INTO sessions VALUES ('20261120_1', 'Demo goose session', '', '/tmp/demo-proj', '2026-11-20 09:59:00', '2026-11-20 10:03:00');
INSERT INTO messages(message_id, session_id, role, content_json, created_timestamp) VALUES ('m1', '20261120_1', 'user', '[{"type":"text","text":"Install the demo deps"}]', 1795168740);
INSERT INTO messages(message_id, session_id, role, content_json, created_timestamp) VALUES ('m2', '20261120_1', 'assistant',
  '[{"type":"text","text":"I need to run an installer."},{"type":"toolRequest","id":"tr1","toolCall":{"status":"success","value":{"name":"developer__shell","arguments":{"command":"npm install"}}}},{"type":"toolConfirmationRequest","id":"tr1","toolName":"developer__shell","arguments":{"command":"npm install"},"prompt":"Allow npm install?"}]', 1795168980);

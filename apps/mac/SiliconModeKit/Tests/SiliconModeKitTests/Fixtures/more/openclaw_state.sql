-- Synthetic OpenClaw gateway state DB: one pending exec approval, one resolved, one expired.
CREATE TABLE operator_approvals (
  approval_id TEXT NOT NULL PRIMARY KEY, resolution_ref TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL,
  presentation_json TEXT NOT NULL, reviewer_device_ids_json TEXT NOT NULL DEFAULT '[]', source_agent_id TEXT,
  source_session_key TEXT, source_session_id TEXT, source_run_id TEXT, source_tool_call_id TEXT, source_tool_name TEXT,
  audience_session_keys_json TEXT NOT NULL DEFAULT '[]', runtime_epoch TEXT NOT NULL DEFAULT 'e1',
  created_at_ms INTEGER NOT NULL, expires_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, decision TEXT
);
INSERT INTO operator_approvals VALUES ('appr-1', 'ref1', 'exec', 'pending',
  '{"kind":"exec","commandText":"rm -rf ./build","commandPreview":"rm -rf ./build","warningText":"Deletes files","allowedDecisions":["allow-once","allow-always","deny"]}',
  '[]', 'main', 'agent:main:demo', 'sid-1', 'run-1', 'tc-1', 'exec', '[]', 'e1', 1795168740000, 1795172400000, 1795168740000, NULL);
INSERT INTO operator_approvals VALUES ('appr-2', 'ref2', 'exec', 'allowed', '{"kind":"exec","commandText":"ls"}',
  '[]', 'main', 'agent:main:demo', 'sid-1', 'run-1', 'tc-0', 'exec', '[]', 'e1', 1795168600000, 1795172400000, 1795168610000, 'allow-once');
INSERT INTO operator_approvals VALUES ('appr-3', 'ref3', 'plugin', 'pending',
  '{"kind":"plugin","title":"Post to channel","description":"Send a message","severity":"warning","allowedDecisions":["allow-once","deny"]}',
  '[]', 'main', 'agent:main:other', 'sid-2', 'run-2', 'tc-2', 'notify', '[]', 'e1', 1795160000000, 1795160600000, 1795160000000, NULL);

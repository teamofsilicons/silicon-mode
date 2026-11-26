-- Synthetic Cursor CLI store.db. meta '0' is hex-encoded JSON:
-- {"agentId":"cur-0001","name":"Demo cursor chat","lastUsedModel":"demo-cursor-model"}
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);
INSERT INTO meta VALUES ('0', '7b226167656e744964223a226375722d30303031222c226e616d65223a2244656d6f20637572736f722063686174222c226c617374557365644d6f64656c223a2264656d6f2d637572736f722d6d6f64656c227d');
INSERT INTO blobs VALUES ('h1', CAST('{"role":"user","content":[{"type":"text","text":"Format the demo code"}]}' AS BLOB));
INSERT INTO blobs VALUES ('h2', X'0a0b120962696e617279');
INSERT INTO blobs VALUES ('h3', CAST('{"role":"assistant","content":[{"type":"text","text":"Formatted 3 files."}]}' AS BLOB));

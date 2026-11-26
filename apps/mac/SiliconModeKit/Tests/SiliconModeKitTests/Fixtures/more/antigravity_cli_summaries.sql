-- Synthetic agy CLI conversation_summaries.db (subset of the real schema).
CREATE TABLE `conversation_summaries` (`conversation_id` text,`title` text NOT NULL DEFAULT "",`preview` text NOT NULL DEFAULT "",
  `step_count` integer NOT NULL DEFAULT 0,`last_modified_time` datetime NOT NULL,`workspace_uris` text NOT NULL,`status` text NOT NULL DEFAULT "",
  `source` text NOT NULL DEFAULT "",`nesting_depth` integer NOT NULL DEFAULT 0,`not_fully_idle` numeric NOT NULL DEFAULT false,
  `killed` numeric NOT NULL DEFAULT false,`last_user_input_time` datetime NOT NULL, PRIMARY KEY (`conversation_id`));
INSERT INTO conversation_summaries VALUES ('agy-run-1','Demo CLI task','Running the linter',12,'2026-11-20 10:04:30.000000+00:00','["file:///tmp/demo-proj"]','CASCADE_RUN_STATUS_RUNNING','CORTEX_TRAJECTORY_SOURCE_CLI',0,1,0,'2026-11-20 10:00:00+00:00');
INSERT INTO conversation_summaries VALUES ('agy-done-2','Finished task','All done',5,'2026-11-20 09:58:00.000000+00:00','["file:///tmp/other"]','CASCADE_RUN_STATUS_IDLE','CORTEX_TRAJECTORY_SOURCE_CLI',0,0,0,'2026-11-20 09:50:00+00:00');
INSERT INTO conversation_summaries VALUES ('agy-sub-3','Subagent','x',2,'2026-11-20 10:04:00.000000+00:00','[]','CASCADE_RUN_STATUS_RUNNING','CORTEX_TRAJECTORY_SOURCE_CLI',1,1,0,'2026-11-20 10:00:00+00:00');
INSERT INTO conversation_summaries VALUES ('agy-old-4','Old','x',2,'2026-11-10 10:04:00.000000+00:00','[]','CASCADE_RUN_STATUS_IDLE','CORTEX_TRAJECTORY_SOURCE_CLI',0,0,0,'2026-11-10 10:00:00+00:00');

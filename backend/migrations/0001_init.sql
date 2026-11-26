-- Silicon Mode backend schema (Silicon Cell `silicon-mode`). Contract shared by the Mac app,
-- web app (mode.teamofsilicons.com), Android and iOS. Source: docs/research/cells.md §4.
--
-- Every row carries user_uuid (= auth.uid(), the Silicon account uuid). Each Mac is a `devices`
-- row; everything it reports is keyed by device_id so several Macs stay separate.
-- Mac → `rpc/push_batch({"p": batch})`. Phone/web → REST reads + realtime, answers via
-- `rpc/answer_question`. Mac ← realtime `answers` INSERT (device_id=eq.<mac>) or push_batch reply.

-- ===== devices: every Mac / phone / web install of a user ===================
CREATE TABLE public.devices (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_uuid    uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(uuid),
  install_id   uuid NOT NULL,                         -- random per install, kept in Keychain/Keystore
  kind         text NOT NULL CHECK (kind IN ('mac','iphone','android','web')),
  name         text NOT NULL CHECK (char_length(name) <= 120),
  model        text CHECK (char_length(model) <= 80),          -- e.g. MacBookPro18,1
  os_version   text CHECK (char_length(os_version) <= 40),
  app_version  text CHECK (char_length(app_version) <= 40),
  timezone     text CHECK (char_length(timezone) <= 64),       -- IANA
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz,
  UNIQUE (user_uuid, install_id),
  UNIQUE (id, user_uuid)
);

-- ===== agent sessions ========================================================
CREATE TABLE public.agent_sessions (
  id                  uuid PRIMARY KEY,               -- client UUIDv5(device_id, provider, provider_session_id), lowercase
  user_uuid           uuid NOT NULL DEFAULT auth.uid(),
  device_id           uuid NOT NULL,
  provider            text NOT NULL CHECK (provider ~ '^[a-z0-9_.:-]{1,64}$'), -- claude_code, codex, grok, antigravity, opencode, pi, hermes, openclaw, silicon, custom:x
  provider_session_id text NOT NULL CHECK (char_length(provider_session_id) <= 200),
  title               text CHECK (char_length(title) <= 300),
  cwd                 text CHECK (char_length(cwd) <= 1024),
  project             text CHECK (char_length(project) <= 200),
  model               text CHECK (char_length(model) <= 120),
  state               text NOT NULL DEFAULT 'working'
                      CHECK (state IN ('starting','working','waiting','idle','finished','failed','unknown')),
  waiting_reason      text CHECK (waiting_reason IN ('permission','question','input','plan')),
  started_at          timestamptz NOT NULL DEFAULT now(),
  last_event_at       timestamptz NOT NULL DEFAULT now(),
  ended_at            timestamptz,
  meta                jsonb NOT NULL DEFAULT '{}' CHECK (octet_length(meta::text) <= 4096),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (device_id, provider, provider_session_id),
  UNIQUE (id, user_uuid),
  FOREIGN KEY (device_id, user_uuid) REFERENCES public.devices (id, user_uuid) ON DELETE CASCADE
);
CREATE INDEX agent_sessions_recent ON public.agent_sessions (user_uuid, device_id, last_event_at DESC);

-- ===== events: capped tail log ===============================================
CREATE TABLE public.events (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_uuid  uuid NOT NULL DEFAULT auth.uid(),
  device_id  uuid NOT NULL,
  session_id uuid NOT NULL,
  seq        bigint NOT NULL,                         -- contiguous per session, assigned by the Mac
  at         timestamptz NOT NULL,
  kind       text NOT NULL CHECK (kind IN ('user','assistant','tool_call','tool_result','status','error','question','answer','log')),
  summary    text NOT NULL CHECK (char_length(summary) <= 500),
  detail     jsonb CHECK (detail IS NULL OR octet_length(detail::text) <= 4096),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (session_id, seq),
  FOREIGN KEY (session_id, user_uuid) REFERENCES public.agent_sessions (id, user_uuid) ON DELETE CASCADE,
  FOREIGN KEY (device_id, user_uuid)  REFERENCES public.devices (id, user_uuid) ON DELETE CASCADE
);
CREATE INDEX events_device_recent ON public.events (device_id, at DESC);
CREATE INDEX events_created ON public.events (created_at);

-- ===== questions (pending prompts / permissions) + answers ===================
CREATE TABLE public.questions (
  id          uuid PRIMARY KEY,                       -- client-generated
  user_uuid   uuid NOT NULL DEFAULT auth.uid(),
  device_id   uuid NOT NULL,
  session_id  uuid,
  kind        text NOT NULL CHECK (kind IN ('permission','question','plan','input')),
  title       text NOT NULL CHECK (char_length(title) <= 300),
  body        text CHECK (char_length(body) <= 8000),
  options     jsonb NOT NULL DEFAULT '[]'             -- [{"id":"allow_once","label":"Allow once","role":"allow"}, …]
              CHECK (jsonb_typeof(options) = 'array' AND jsonb_array_length(options) <= 12),
  allow_text  boolean NOT NULL DEFAULT false,
  state       text NOT NULL DEFAULT 'pending'
              CHECK (state IN ('pending','answered','resolved_on_mac','expired','cancelled')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz,
  resolved_at timestamptz,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, user_uuid, device_id),
  FOREIGN KEY (session_id, user_uuid) REFERENCES public.agent_sessions (id, user_uuid) ON DELETE CASCADE,
  FOREIGN KEY (device_id, user_uuid)  REFERENCES public.devices (id, user_uuid) ON DELETE CASCADE
);
CREATE INDEX questions_pending ON public.questions (user_uuid, device_id) WHERE state = 'pending';

CREATE TABLE public.answers (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id   uuid NOT NULL UNIQUE,                 -- first answer wins
  user_uuid     uuid NOT NULL DEFAULT auth.uid(),
  device_id     uuid NOT NULL,                        -- the Mac that owns the question (realtime filter key)
  option_id     text CHECK (char_length(option_id) <= 64),
  text          text CHECK (char_length(text) <= 8000),
  answered_from text NOT NULL CHECK (answered_from IN ('mac','iphone','android','web')),
  answered_by   uuid,                                 -- devices.id of the answering client (optional)
  created_at    timestamptz NOT NULL DEFAULT now(),
  consumed_at   timestamptz,
  outcome       text CHECK (outcome IN ('applied','stale','failed')),
  CHECK (option_id IS NOT NULL OR text IS NOT NULL),
  FOREIGN KEY (question_id, user_uuid, device_id) REFERENCES public.questions (id, user_uuid, device_id) ON DELETE CASCADE
);
CREATE INDEX answers_unconsumed ON public.answers (device_id) WHERE consumed_at IS NULL;

-- ===== Silicon Mode status: one row per device ===============================
CREATE TABLE public.device_status (
  device_id         uuid PRIMARY KEY,
  user_uuid         uuid NOT NULL DEFAULT auth.uid(),
  mode              text NOT NULL DEFAULT 'off' CHECK (mode IN ('off','arming','active','locked','panic')),
  mode_since        timestamptz NOT NULL DEFAULT now(),
  lid_angle         real,
  silicon_angle     real,
  caffeinated       boolean NOT NULL DEFAULT false,
  face              text CHECK (char_length(face) <= 80),
  agents_working    smallint NOT NULL DEFAULT 0,
  agents_waiting    smallint NOT NULL DEFAULT 0,
  agents_finished   smallint NOT NULL DEFAULT 0,
  questions_pending smallint NOT NULL DEFAULT 0,
  online            boolean NOT NULL DEFAULT true,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (device_id, user_uuid) REFERENCES public.devices (id, user_uuid) ON DELETE CASCADE
);

-- ===== hourly usage buckets (local hours, for the 24h x days heatmap) ========
CREATE TABLE public.usage_hourly (
  device_id            uuid NOT NULL,
  hour_start           timestamptz NOT NULL CHECK (extract(epoch FROM hour_start)::bigint % 900 = 0), -- instant the LOCAL hour began (+05:30 / +05:45 safe)
  user_uuid            uuid NOT NULL DEFAULT auth.uid(),
  local_date           date NOT NULL,
  local_hour           smallint NOT NULL CHECK (local_hour BETWEEN 0 AND 23),
  utc_offset_min       smallint NOT NULL CHECK (utc_offset_min BETWEEN -840 AND 840),
  agent_seconds        integer NOT NULL DEFAULT 0 CHECK (agent_seconds >= 0),      -- sum over agents
  max_concurrent       smallint NOT NULL DEFAULT 0 CHECK (max_concurrent >= 0),
  sessions_started     smallint NOT NULL DEFAULT 0 CHECK (sessions_started >= 0),
  silicon_mode_seconds smallint NOT NULL DEFAULT 0 CHECK (silicon_mode_seconds BETWEEN 0 AND 3600),
  by_provider          jsonb NOT NULL DEFAULT '{}',   -- {"claude_code":1800,"codex":600}
  updated_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (device_id, hour_start),
  FOREIGN KEY (device_id, user_uuid) REFERENCES public.devices (id, user_uuid) ON DELETE CASCADE
);
CREATE INDEX usage_hourly_user_date ON public.usage_hourly (user_uuid, local_date);


ALTER TABLE public.devices        ENABLE ROW LEVEL SECURITY;  -- already on via _cells.on_ddl; harmless
ALTER TABLE public.agent_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.events         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.questions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.answers        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_status  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usage_hourly   ENABLE ROW LEVEL SECURITY;

CREATE POLICY own_rows ON public.devices        FOR ALL USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.agent_sessions FOR ALL USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.events         FOR ALL USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.questions      FOR ALL USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.device_status  FOR ALL USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.usage_hourly   FOR ALL USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));

-- answers: read/consume own; insert only for an own, still-pending, unexpired question
CREATE POLICY answers_read    ON public.answers FOR SELECT USING (user_uuid = (SELECT auth.uid()));
CREATE POLICY answers_consume ON public.answers FOR UPDATE USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));
CREATE POLICY answers_insert  ON public.answers FOR INSERT WITH CHECK (
  user_uuid = (SELECT auth.uid()) AND EXISTS (
    SELECT 1 FROM public.questions q
    WHERE q.id = question_id AND q.user_uuid = (SELECT auth.uid()) AND q.device_id = answers.device_id
      AND q.state = 'pending' AND (q.expires_at IS NULL OR q.expires_at > now())));


CREATE FUNCTION public.register_device(p_install_id uuid, p_kind text, p_name text, p_model text DEFAULT NULL,
  p_os_version text DEFAULT NULL, p_app_version text DEFAULT NULL, p_timezone text DEFAULT NULL)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path = public, pg_catalog AS $$
  INSERT INTO devices (user_uuid, install_id, kind, name, model, os_version, app_version, timezone)
  VALUES (auth.uid(), p_install_id, p_kind, p_name, p_model, p_os_version, p_app_version, p_timezone)
  ON CONFLICT (user_uuid, install_id) DO UPDATE SET name = excluded.name, model = excluded.model,
    os_version = excluded.os_version, app_version = excluded.app_version, timezone = excluded.timezone,
    last_seen_at = now(), revoked_at = NULL
  RETURNING id
$$;

-- Mac -> cell: one call per flush. Idempotent: client UUIDs, (session_id,seq), absolute usage totals.
CREATE FUNCTION public.push_batch(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog AS $$
DECLARE
  uid  uuid := auth.uid();
  dev  uuid := (p->>'device_id')::uuid;
  tail int  := least(greatest(coalesce((p->>'tail_limit')::int, 30), 10), 200);
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'sign in required' USING ERRCODE = '28000'; END IF;
  UPDATE devices SET last_seen_at = now(), app_version = coalesce(p->>'app_version', app_version)
   WHERE id = dev AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown device' USING ERRCODE = 'P0002'; END IF;

  INSERT INTO agent_sessions AS s (id, user_uuid, device_id, provider, provider_session_id, title, cwd, project,
         model, state, waiting_reason, started_at, last_event_at, ended_at, meta, updated_at)
  SELECT x.id, uid, dev, x.provider, x.provider_session_id, x.title, x.cwd, x.project, x.model,
         coalesce(x.state,'working'), x.waiting_reason, coalesce(x.started_at, now()),
         coalesce(x.last_event_at, now()), x.ended_at, coalesce(x.meta,'{}'), now()
  FROM jsonb_to_recordset(coalesce(p->'sessions','[]')) AS x(id uuid, provider text, provider_session_id text,
       title text, cwd text, project text, model text, state text, waiting_reason text,
       started_at timestamptz, last_event_at timestamptz, ended_at timestamptz, meta jsonb)
  ON CONFLICT (id) DO UPDATE SET title = excluded.title, cwd = excluded.cwd, project = excluded.project,
       model = excluded.model, state = excluded.state, waiting_reason = excluded.waiting_reason,
       last_event_at = greatest(s.last_event_at, excluded.last_event_at), ended_at = excluded.ended_at,
       meta = excluded.meta, updated_at = now();

  INSERT INTO events (user_uuid, device_id, session_id, seq, at, kind, summary, detail)
  SELECT uid, dev, e.session_id, e.seq, e.at, e.kind, left(e.summary, 500), e.detail
  FROM jsonb_to_recordset(coalesce(p->'events','[]')) AS e(session_id uuid, seq bigint, at timestamptz,
       kind text, summary text, detail jsonb)
  ON CONFLICT (session_id, seq) DO NOTHING;

  DELETE FROM events ev
  USING (SELECT session_id, max(seq) AS top FROM events
         WHERE session_id IN (SELECT DISTINCT (e->>'session_id')::uuid
                              FROM jsonb_array_elements(coalesce(p->'events','[]')) e)
         GROUP BY session_id) m
  WHERE ev.session_id = m.session_id AND ev.seq <= m.top - tail;

  IF jsonb_typeof(p->'status') = 'object' THEN
    INSERT INTO device_status AS d (device_id, user_uuid, mode, mode_since, lid_angle, silicon_angle, caffeinated,
           face, agents_working, agents_waiting, agents_finished, questions_pending, online, updated_at)
    SELECT dev, uid, x.mode, coalesce(x.mode_since, now()), x.lid_angle, x.silicon_angle, coalesce(x.caffeinated,false),
           x.face, coalesce(x.agents_working,0), coalesce(x.agents_waiting,0), coalesce(x.agents_finished,0),
           coalesce(x.questions_pending,0), coalesce(x.online,true), now()
    FROM jsonb_to_record(p->'status') AS x(mode text, mode_since timestamptz, lid_angle real, silicon_angle real,
         caffeinated boolean, face text, agents_working smallint, agents_waiting smallint, agents_finished smallint,
         questions_pending smallint, online boolean)
    ON CONFLICT (device_id) DO UPDATE SET mode = excluded.mode, mode_since = excluded.mode_since,
         lid_angle = excluded.lid_angle, silicon_angle = excluded.silicon_angle, caffeinated = excluded.caffeinated,
         face = excluded.face, agents_working = excluded.agents_working, agents_waiting = excluded.agents_waiting,
         agents_finished = excluded.agents_finished, questions_pending = excluded.questions_pending,
         online = excluded.online, updated_at = now();
  END IF;

  INSERT INTO questions (id, user_uuid, device_id, session_id, kind, title, body, options, allow_text, expires_at)
  SELECT q.id, uid, dev, q.session_id, q.kind, q.title, q.body, coalesce(q.options,'[]'), coalesce(q.allow_text,false), q.expires_at
  FROM jsonb_to_recordset(coalesce(p->'questions','[]')) AS q(id uuid, session_id uuid, kind text, title text,
       body text, options jsonb, allow_text boolean, expires_at timestamptz)
  ON CONFLICT (id) DO NOTHING;

  UPDATE questions q SET state = u.state, resolved_at = now(), updated_at = now()
  FROM jsonb_to_recordset(coalesce(p->'question_updates','[]')) AS u(id uuid, state text)
  WHERE q.id = u.id AND q.device_id = dev AND q.state = 'pending';

  UPDATE answers a SET consumed_at = now(), outcome = c.outcome
  FROM jsonb_to_recordset(coalesce(p->'consumed','[]')) AS c(id uuid, outcome text)
  WHERE a.id = c.id AND a.device_id = dev AND a.consumed_at IS NULL;

  INSERT INTO usage_hourly AS h (device_id, hour_start, user_uuid, local_date, local_hour, utc_offset_min,
         agent_seconds, max_concurrent, sessions_started, silicon_mode_seconds, by_provider, updated_at)
  SELECT dev, x.hour_start, uid, x.local_date, x.local_hour, x.utc_offset_min, x.agent_seconds, x.max_concurrent,
         x.sessions_started, x.silicon_mode_seconds, coalesce(x.by_provider,'{}'), now()
  FROM jsonb_to_recordset(coalesce(p->'usage','[]')) AS x(hour_start timestamptz, local_date date, local_hour smallint,
       utc_offset_min smallint, agent_seconds integer, max_concurrent smallint, sessions_started smallint,
       silicon_mode_seconds smallint, by_provider jsonb)
  ON CONFLICT (device_id, hour_start) DO UPDATE SET
       agent_seconds = greatest(h.agent_seconds, excluded.agent_seconds),
       max_concurrent = greatest(h.max_concurrent, excluded.max_concurrent),
       sessions_started = greatest(h.sessions_started, excluded.sessions_started),
       silicon_mode_seconds = greatest(h.silicon_mode_seconds, excluded.silicon_mode_seconds),
       by_provider = excluded.by_provider, updated_at = now();

  RETURN jsonb_build_object('server_time', now(), 'answers', coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', a.id, 'question_id', a.question_id, 'option_id', a.option_id,
             'text', a.text, 'answered_from', a.answered_from, 'created_at', a.created_at) ORDER BY a.created_at)
    FROM answers a WHERE a.device_id = dev AND a.consumed_at IS NULL), '[]'::jsonb));
END $$;

-- phone/web -> cell: first answer wins; tells the caller if it lost the race
CREATE FUNCTION public.answer_question(p_question uuid, p_option text DEFAULT NULL, p_text text DEFAULT NULL,
  p_from text DEFAULT 'web', p_by uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog AS $$
DECLARE q questions; a_id uuid;
BEGIN
  SELECT * INTO q FROM questions WHERE id = p_question FOR UPDATE;   -- RLS: own rows only
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF q.state <> 'pending' OR (q.expires_at IS NOT NULL AND q.expires_at <= now()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', q.state); END IF;
  IF p_option IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(q.options) o WHERE o->>'id' = p_option) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_option'); END IF;
  INSERT INTO answers (question_id, user_uuid, device_id, option_id, text, answered_from, answered_by)
  VALUES (q.id, q.user_uuid, q.device_id, p_option, p_text, p_from, p_by)
  ON CONFLICT (question_id) DO NOTHING RETURNING id INTO a_id;
  IF a_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'already_answered'); END IF;
  RETURN jsonb_build_object('ok', true, 'answer_id', a_id);
END $$;

-- heatmap: rows = (local_date, local_hour); missing cells = 0
CREATE FUNCTION public.usage_heatmap(p_days integer DEFAULT 35, p_device uuid DEFAULT NULL)
RETURNS TABLE (local_date date, local_hour smallint, agent_seconds bigint, max_concurrent smallint,
               sessions_started bigint, devices bigint)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public, pg_catalog AS $$
  SELECT h.local_date, h.local_hour, sum(h.agent_seconds)::bigint, max(h.max_concurrent),
         sum(h.sessions_started)::bigint, count(DISTINCT h.device_id)
  FROM usage_hourly h
  WHERE h.user_uuid = auth.uid()
    AND h.local_date >= current_date - least(greatest(p_days, 1), 366)
    AND (p_device IS NULL OR h.device_id = p_device)
  GROUP BY 1, 2 ORDER BY 1, 2
$$;


DO $grant$
DECLARE api text;
BEGIN
  SELECT r.rolname INTO STRICT api
  FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid
  WHERE m.member = (SELECT oid FROM pg_roles WHERE rolname = current_user) AND r.rolname LIKE 'cla\_%';
  EXECUTE format('GRANT EXECUTE ON FUNCTION public.register_device(uuid,text,text,text,text,text,text),
                  public.push_batch(jsonb), public.answer_question(uuid,text,text,text,uuid),
                  public.usage_heatmap(integer,uuid) TO %I', api);
END $grant$;
-- Fallback if STRICT fails: GRANT … TO "cla_<cell uuid without dashes>" (uuid from `silicon-cells show silicon-mode --json`).

-- Silicon Mode backend (Silicon Cell `silicon-mode`).
--
-- Every row belongs to the signed-in Silicon account (`owner` = auth.uid()). A user may have
-- several Macs ("devices"); everything a Mac reports is keyed by its device so they stay separate.
--
-- Data flow
--   Mac  → upserts device, device_status, agent_sessions, agent_events, questions, usage_hourly
--   Phone/Web → read everything; answer a question by setting status='answered' + answer
--   Mac  ← realtime on questions (status='answered') → delivers the answer to the agent,
--          then sets status='resolved'. Questions answered at the terminal become 'resolved' too.

create table if not exists devices (
    id            uuid primary key default gen_random_uuid(),
    owner         uuid not null default auth.uid(),
    device_key    text not null,               -- random id generated once per Mac install
    name          text not null default 'Mac', -- "Shubham's MacBook Pro"
    model         text,                        -- hw.model, e.g. MacBookPro18,1
    os_version    text,
    app_version   text,
    has_lid_sensor boolean not null default true,
    created_at    timestamptz not null default now(),
    last_seen_at  timestamptz not null default now(),
    unique (owner, device_key)
);

-- One row per device: what the Mac is doing right now.
create table if not exists device_status (
    device_id     uuid primary key references devices(id) on delete cascade,
    owner         uuid not null default auth.uid(),
    mode          text not null default 'idle' check (mode in ('idle','countdown','active','locked')),
    panic         boolean not null default false,
    entered_at    timestamptz,                 -- when Silicon Mode started (null when idle)
    lid_angle     real,
    face_id       text,
    needs_you     integer not null default 0,
    working       integer not null default 0,
    finished      integer not null default 0,
    idle          integer not null default 0,
    updated_at    timestamptz not null default now()
);

create table if not exists agent_sessions (
    device_id     uuid not null references devices(id) on delete cascade,
    id            text not null,               -- "<provider>:<native id>"
    owner         uuid not null default auth.uid(),
    provider      text not null,               -- claude-code | codex | opencode | …
    title         text not null default '',
    project       text,                        -- folder name only (never full paths)
    state         text not null check (state in ('needs_you','working','finished','idle','error')),
    model         text,
    started_at    timestamptz,
    updated_at    timestamptz not null default now(),
    gone          boolean not null default false, -- no longer detected on the Mac
    primary key (device_id, id)
);
create index if not exists agent_sessions_owner_updated on agent_sessions (owner, updated_at desc);

-- Tail log. The Mac keeps at most ~50 per session (older rows pruned by the Mac / a job).
create table if not exists agent_events (
    id            bigint generated always as identity primary key,
    device_id     uuid not null references devices(id) on delete cascade,
    session_id    text not null,
    owner         uuid not null default auth.uid(),
    event_key     text not null,               -- provider event id, for idempotent upserts
    at            timestamptz not null,
    kind          text not null,               -- user|assistant|thinking|tool|tool_result|permission|question|status|error
    text          text not null,
    unique (device_id, session_id, event_key)
);
create index if not exists agent_events_session_at on agent_events (device_id, session_id, at desc);
create index if not exists agent_events_owner_at on agent_events (owner, at desc);

create table if not exists questions (
    device_id     uuid not null references devices(id) on delete cascade,
    id            text not null,               -- provider-scoped question id
    owner         uuid not null default auth.uid(),
    session_id    text not null,
    provider      text not null,
    kind          text not null check (kind in ('permission','question','input')),
    title         text not null,
    detail        text,
    options       jsonb not null default '[]'::jsonb,  -- [{id,label,detail,style}]
    allows_free_text boolean not null default false,
    multi_select  boolean not null default false,
    answerable    boolean not null default true,
    status        text not null default 'pending' check (status in ('pending','answered','resolved','expired','failed')),
    answer        jsonb,                               -- {option_ids:[…], text, source}
    answered_at   timestamptz,
    error         text,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    primary key (device_id, id)
);
create index if not exists questions_owner_status on questions (owner, status, created_at desc);

-- Hourly usage buckets for the 24h × days heatmap.
create table if not exists usage_hourly (
    device_id     uuid not null references devices(id) on delete cascade,
    hour          timestamptz not null,        -- truncated to the hour (UTC)
    owner         uuid not null default auth.uid(),
    agent_minutes real not null default 0,     -- Σ running agents × minutes
    max_concurrent integer not null default 0,
    sessions_started integer not null default 0,
    silicon_mode_minutes real not null default 0,
    by_provider   jsonb not null default '{}'::jsonb,  -- {"claude-code": minutes, …}
    primary key (device_id, hour)
);
create index if not exists usage_hourly_owner_hour on usage_hourly (owner, hour desc);

-- updated_at maintenance
create or replace function touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists device_status_touch on device_status;
create trigger device_status_touch before update on device_status for each row execute function touch_updated_at();
drop trigger if exists questions_touch on questions;
create trigger questions_touch before update on questions for each row execute function touch_updated_at();

-- Row-level security: owners only, on every table.
alter table devices        enable row level security;
alter table device_status  enable row level security;
alter table agent_sessions enable row level security;
alter table agent_events   enable row level security;
alter table questions      enable row level security;
alter table usage_hourly   enable row level security;

do $$
declare t text;
begin
  foreach t in array array['devices','device_status','agent_sessions','agent_events','questions','usage_hourly'] loop
    execute format('drop policy if exists %I on %I', t || '_own', t);
    execute format(
      'create policy %I on %I for all using (owner = auth.uid()) with check (owner = auth.uid())',
      t || '_own', t);
  end loop;
end $$;

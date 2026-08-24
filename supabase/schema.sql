-- Wisper sync schema. Paste into the Supabase SQL editor and run once.
-- Auth: each user sees only their own rows (RLS on auth.uid()).
-- Clients talk plain PostgREST + GoTrue, so any platform can sync.

-- Append-only dictation history.
create table if not exists transcripts (
    id uuid primary key,
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    device text not null,
    ts timestamptz not null,
    raw text not null,
    clean text,
    duration_s double precision not null default 0,
    word_count integer not null default 0,
    app_bundle text,
    delivery text not null default 'pasted',
    asr_ms integer,
    cleanup_ms integer,
    created_at timestamptz not null default now()
);

create index if not exists transcripts_user_created on transcripts (user_id, created_at);

alter table transcripts enable row level security;

create policy "own transcripts select" on transcripts for select using (user_id = auth.uid());
create policy "own transcripts insert" on transcripts for insert with check (user_id = auth.uid());
create policy "own transcripts update" on transcripts for update using (user_id = auth.uid());
create policy "own transcripts delete" on transcripts for delete using (user_id = auth.uid());

-- Whole-document sync (last-write-wins) for the personal dictionary,
-- voice commands, and each skill.
--   kind: 'dictionary' | 'commands' | 'skill'
--   name: 'dictionary.txt' | 'commands.json' | the skill's name
create table if not exists sync_documents (
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    kind text not null,
    name text not null,
    content text not null,
    updated_at timestamptz not null default now(),
    updated_by text not null,
    primary key (user_id, kind, name)
);

alter table sync_documents enable row level security;

create policy "own documents select" on sync_documents for select using (user_id = auth.uid());
create policy "own documents insert" on sync_documents for insert with check (user_id = auth.uid());
create policy "own documents update" on sync_documents for update using (user_id = auth.uid());
create policy "own documents delete" on sync_documents for delete using (user_id = auth.uid());

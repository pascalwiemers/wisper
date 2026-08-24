# Wisper sync protocol

Plain Supabase REST — no platform SDKs required. Any client (the Linux app)
that implements this talks to the same data.

## Setup

1. Run `schema.sql` in the project's SQL editor (once).
2. Client config: project URL + anon key.
3. Auth: GoTrue email/password.
   - Sign up: `POST {url}/auth/v1/signup` `{"email","password"}` (apikey header)
   - Sign in: `POST {url}/auth/v1/token?grant_type=password` → `access_token`, `refresh_token`, `expires_in`
   - Refresh: `POST {url}/auth/v1/token?grant_type=refresh_token` `{"refresh_token"}`
4. Every REST call: headers `apikey: <anon>` and `Authorization: Bearer <access_token>`.
   RLS scopes all rows to the signed-in user automatically; never send `user_id`.

## Transcripts (append-only)

Each device keeps its rows locally with a lowercase UUID and a `synced` flag.

- **Push**: `POST {url}/rest/v1/transcripts?on_conflict=id` with
  `Prefer: resolution=merge-duplicates,return=minimal` and a JSON array of
  `{id, device, ts, raw, clean?, duration_s, word_count, app_bundle?, delivery, asr_ms?, cleanup_ms?}`
  (`ts` ISO-8601 with fractional seconds). Mark rows synced on 2xx.
- **Pull**: `GET {url}/rest/v1/transcripts?select=*&device=neq.{me}&created_at=gt.{lastPull}&order=created_at.asc&limit=1000`
  Insert rows whose `id` is unknown locally; advance `lastPull` to the max
  `created_at` seen. `device` is a free-form per-device name.
- Deletions are not synced (local "Delete All History" stays local).

## Documents (last-write-wins)

Personal dictionary, commands, and each skill sync as whole documents in
`sync_documents` keyed by `(kind, name)`:

| kind         | name             | content                     |
|--------------|------------------|-----------------------------|
| `dictionary` | `dictionary.txt` | the dictionary file, verbatim |
| `commands`   | `commands.json`  | the commands file, verbatim |
| `skill`      | `<file name>.md` | one row per skill           |

Client keeps a SHA-256 of each document's content as of the last sync:

- local changed only → upsert (`POST ...?on_conflict=user_id,kind,name`,
  `Prefer: resolution=merge-duplicates`) with `updated_at=now`, `updated_by=<device>`.
- remote changed only → overwrite the local file.
- both changed → last write wins (this client keeps local and pushes); log it.
- Also pull `kind=eq.skill` rows whose names don't exist locally (new skills
  from other devices).

File formats are documented by example in the app's data folder:
`dictionary.txt` (plain words + `wrong -> right` lines), `commands.json`
(`[{trigger, prompt}]`), skills as plain markdown.

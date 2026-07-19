# Roster scale-pack — 50M+ influencers, Sheets sync, 8-hour auto-refresh

This adds a real backend so Roster and Roster Bridge can hold **tens of millions of
influencers** with historical tracking, two-way Google Sheets sync, and automatic
metric refresh from a data provider. The app screens stay the same — they just read
from this backend once it's connected.

## Why a backend (honest note)
A single HTML file / browser can't hold 5 crore (50M) rows — that's gigabytes and needs
indexes. This pack keeps the data in your own Supabase Postgres and paginates it. The app
never downloads all 50M rows; it asks the server for one page at a time with your filters.

## Pieces
| File | Purpose |
|------|---------|
| `supabase-roster-schema.sql` | Tables + indexes: `influencers` (wide, indexed), `influencer_history` (append-only growth), `influencer_content`, `influencer_collabs`, `influencer_docs`, `influencer_notes`, `influencer_comms`, `roster_pnl` view |
| `api/roster-search.js` | Paginated, multi-parameter search (followers, engagement, niches, languages, tags, audience geo, pricing, availability, …) — runs in Postgres |
| `api/sheets-sync.js` | Two-way Google Sheets ⇄ Supabase (pull upserts rows, push writes app changes back) |
| `api/provider-refresh.js` | Pulls fresh metrics from your data provider and **appends** a history snapshot |
| `vercel.json` | Cron: provider refresh every 8h, sheet sync every 30 min |

## Setup
1. **Schema** — run `supabase-roster-schema.sql` in Supabase → SQL editor.
2. **Env vars in Vercel**
   - `SUPABASE_URL`, `SUPABASE_SERVICE_KEY` (service-role key — server-side only, never in the app)
   - Google Sheets: `GOOGLE_SA_EMAIL`, `GOOGLE_SA_KEY`, `SHEET_ID`, `SHEET_RANGE` (e.g. `Roster!A1:Z`)
   - Provider: `PROVIDER_BASE_URL`, `PROVIDER_API_KEY`
3. **Share the sheet** with your Google service-account email (`GOOGLE_SA_EMAIL`) as Editor.
4. **Deploy** — Vercel picks up `vercel.json` and schedules the crons automatically.

## Google Sheets stays your data-entry surface
Your team keeps typing into the sheet. Every 30 min `sheets-sync` pulls new/edited rows and
upserts them (deduped by `platform+handle`), and pushes app-side edits back — so both stay in
sync. Trigger an immediate sync from the app's Roster header (**Sync now**), or POST
`{action:"pull"}` / `{action:"push"}`.

## Auto-refresh every 8 hours
`provider-refresh` runs on cron, picks the most-stale rows (never synced or >8h old), calls your
provider, updates the current row **and inserts a new `influencer_history` snapshot** — so you can
chart follower/engagement growth over time instead of losing the old numbers. It processes a batch
per run; increase `BATCH` or cron frequency to cover more rows per day.

### Provider
The refresh function is **provider-agnostic**. Point it at whichever influencer-data API you use —
Modash, HypeAuditor, Phyllo, IQData, or your "ETA" provider — via `PROVIDER_BASE_URL` +
`PROVIDER_API_KEY`. Adapt `mapProvider()` in `api/provider-refresh.js` to that API's response shape
(followers, engagement, avg likes/comments/views, bio, audience demographics, recent posts, etc.).
> I couldn't verify a mainstream provider literally named "ETA" — if that's your vendor, drop in its
> base URL + key and tweak `mapProvider()`; the plumbing is identical.

## Scale tips
- `influencers` is indexed (btree on numeric fields, GIN on `niches`/`languages`/`tags`/`audience`,
  trigram on `handle`/`name`) so filtered search stays fast at tens of millions of rows.
- For very large history, partition `influencer_history` by month (`PARTITION BY RANGE (captured_at)`).
- Search uses keyset/`range()` pagination — the app requests 50 at a time, never the whole table.
- Move heavy provider back-fills to a queue/worker if you need millions refreshed per day.

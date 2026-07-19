# DiscoverDesk — Architecture & 5-Year Build Plan

Read this before you spend money or hire anyone. It's the honest version.

---

## The one thing you have to accept first

The app you have today is **one HTML file** with data in the browser (`localStorage`)
and an optional Supabase backend. That is a genuinely good **prototype and internal
tool**. It is *not* a platform for 10M influencers / 5M campaigns / 1M brands /
10,000 concurrent employees / 1,000 teams. Nothing I can type into that file
changes this — the ceiling is architectural, not cosmetic.

Getting to the scale you described is a **team + time + money** problem:
real platforms in this space run on engineering teams of dozens over years.
This document is the map from "capable prototype" to "company platform" so you
can scope it properly instead of discovering the walls one crash at a time.

---

## Target scale (your numbers) and what each one demands

| You said | Real implication |
|---|---|
| 1 crore (10M) influencers | Postgres can hold this, but every list/search needs proper **indexes + pagination + full-text search** (or Elasticsearch/Typesense). No "load all rows" anywhere. |
| 50 lakh (5M) campaigns | Same. Plus **partitioning** by tenant/date and archival of old campaigns. |
| 10 lakh (1M) brands | This is your **tenant** dimension. Multi-tenancy must be designed in from row one, not bolted on. |
| 10,000 employees working together | **Auth at scale**, connection pooling (PgBouncer), read replicas, and a real permissions engine. |
| 1,000 teams simultaneously | **Row-Level Security by tenant + team**, plus realtime that doesn't fan out to everyone. |
| Cross-brand connections | A **sharing/permission graph** between tenants — the hardest part. Design carefully or it becomes a data-leak surface. |
| Self-optimizing at big numbers | Autoscaling infra + caching + queues. Not "smooth by magic" — smooth by architecture. |

---

## Recommended stack (pragmatic, not trendy)

**Frontend**
- **Next.js (React)** on **Netlify** or **Vercel**. You already want Netlify — good.
- Keep your current single-file app as the **design reference**: the UI, the module
  map, the flows are all validated. Port them component by component.

**Backend / data**
- **Postgres** (Supabase is fine to start — it *is* Postgres) as the source of truth.
- **PgBouncer** connection pooling once you pass ~a few hundred concurrent users.
- **Read replicas** for dashboards/reports (heavy reads) so they don't slow writes.
- **Redis** for caching hot queries (roster summaries, dashboards) and rate limits.
- **A queue** (e.g. Supabase Edge Functions + a job table, or a real broker like
  SQS/RabbitMQ later) for: Meta refresh, Sheets sync, email, exports of large sets,
  provider crawls. Never do these inline in a request.
- **Object storage** (S3 / Supabase Storage) for exports, media-kit files, reel thumbnails.

**Search** (you cannot skip this at 10M rows)
- Start with Postgres full-text + trigram indexes.
- Move to **Typesense / Meilisearch / Elasticsearch** when creator search gets slow.

**Multi-tenancy (the core decision)**
- Single database, **`tenant_id` (brand/org) on every row**, enforced by **Row-Level
  Security**. This is how you get 1M brands isolated safely without 1M databases.
- Teams are a second dimension: `team_id`, with a membership table.
- Cross-brand sharing = an explicit `shares` table (who shared what, with whom, what
  permission). Default deny. This is where security lives or dies.

**Auth & permissions**
- Supabase Auth / Clerk / Auth0 for identity.
- A **permissions matrix in the DB** (role + per-user overrides — you already have
  the shape of this in the current app's `ROLE_DEFAULTS` + per-user `perms`). Port it.
- **Download/export permission** is already a concept in your app (`export` perm) —
  at scale, log every export (who, what, when) for audit and to catch data exfiltration.

**The rule you asked for is already enforceable in this model**
- Sales/KAM → assign only to Discovery Manager → Manager routes onward.
  (Implemented in tonight's build; in the real backend it becomes a server-side
  check so the client can never bypass it.)
- Primary owner account = a `is_primary` flag + a DB constraint/trigger that refuses
  to delete or deactivate it, and refuses to drop below one active admin.
  (Implemented client-side tonight; must be a **server constraint** in production —
  never trust the browser for this.)

---

## CI/CD (real, once it's a repo)

You can't have CI/CD on a hand-uploaded HTML file. Once it's in **GitHub**:

1. **Netlify/Vercel Git integration** — push to `main` → auto-build → auto-deploy.
2. **Preview deploys** on every pull request (test before it's live).
3. **GitHub Actions** for: lint, type-check, unit tests, and DB migration checks.
4. **Migrations** via a tool (Prisma / Drizzle / Supabase migrations) so schema
   changes are versioned and reversible — never hand-edited SQL in production.
5. **Environment separation**: dev → staging → prod, with separate databases.
6. **Rollback**: Netlify keeps every deploy; one click reverts.

## "Self-sustained / smooth at big numbers" — what that actually is

Not magic. It's:
- **Autoscaling** hosting (serverless functions scale automatically).
- **Caching** so the same dashboard isn't recomputed 10,000 times.
- **Queues** so slow work never blocks a user click.
- **Pagination + indexes** so a 10M-row table returns 50 rows in 20ms.
- **Monitoring + alerts** (Sentry for errors, a metrics dashboard) so you *see*
  the strain before users do.
- **Load testing** before each big onboarding so you know the ceiling in advance.

---

## AI features worth adding (market-aware, next 1–5 years)

Grounded in where influencer-marketing tooling is actually heading:

1. **Semantic creator search** — "find me sporty Gen-Z creators in Tamil Nadu under
   ₹50k who convert" → embeddings over creator profiles, not keyword match.
2. **Fraud / fake-follower detection** — you already show fake%/authentic% scores;
   make them real with engagement-pattern models.
3. **Brand-fit / match scoring** — predict which creators fit a brief from history.
4. **Auto-generated outreach & briefs** — draft the first message / campaign brief.
5. **Performance forecasting** — expected reach/engagement/CPV before you book.
6. **The assistant** you have → upgrade from rules to a real model **server-side**,
   grounded in the user's permitted data (RAG), so it truly answers anything
   without leaking across tenants.
7. **Anomaly alerts** — "this creator's engagement dropped 40% this month."

Each is a project. Prioritise by what closes deals: match-scoring and fraud
detection tend to be the differentiators buyers pay for.

---

## Suggested phasing (so it's fundable and testable)

- **Phase 0 (now):** Keep the prototype live for real internal use. Learn from it.
- **Phase 1 (backend foundation):** Next.js + Postgres + Auth + RLS multi-tenancy.
  Port modules. Real server-side permissions. CI/CD. *This is the big one.*
- **Phase 2 (scale):** Search engine, caching, queues, read replicas, monitoring,
  load testing. Onboard first real tenants.
- **Phase 3 (collaboration):** Teams, cross-brand sharing graph, granular download
  controls, audit logging.
- **Phase 4 (intelligence):** Semantic search, match-scoring, fraud detection.
- **Phase 5 (platform):** Public API, marketplace, integrations, white-label.

---

## What I did tonight (in the current app, honestly scoped)

These are real and shipped in `index.html`:

1. **Assignment routing rule** — Sales/KAM can assign **only** to a Discovery
   Manager; Manager routes onward; Admin to anyone. Enforced in the dropdown **and**
   in the assign/bulk-assign actions so it can't be bypassed.
2. **Primary owner protection** — first account is the permanent owner: cannot be
   deactivated or deleted; app always keeps ≥1 active admin.
3. **Account management** — deactivate / delete other accounts, with a confirm step;
   deleting someone re-flags their live work instead of losing it.
4. **Import corruption guards** — 100k-row cap with honest warning, in-file
   duplicate detection, follower-count clamping, source-URL capture, and a truthful
   summary (new / updated / merged / skipped) instead of a misleading row count.
5. **Request dashboard** — a live, clickable summary strip (open / in discovery /
   in review / delivered / unassigned / overdue / delivery-rate) above the table.
6. **Chatbot** — now explains the assignment rule and the owner-protection rule,
   on top of the module-aware answers from the last build.

## What I did NOT do (and why)

- 10M-record backend, 10k concurrency, multi-tenancy, cross-brand sharing, CI/CD,
  self-optimizing infra, the AI features above — **all Phase 1–4 work above.**
  They are not edits to a static file; they're the actual platform build.
- If you want to start Phase 1, the next concrete step is: create a GitHub repo,
  stand up a Next.js skeleton, and port the **Roster** module to Postgres first
  (it's your highest-value, highest-volume data). I can help scaffold that when
  you're ready to work in a repo instead of a single file.

Don't let anyone (including an AI) tell you the whole thing is done in one night.
Build it in phases, test each one under load, and it'll actually hold.

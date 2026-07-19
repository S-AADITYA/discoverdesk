# DiscoverDesk — One-Pager (for investors & developers)

## What it is
An AI-powered **creator discovery & campaign intelligence platform** for influencer-
marketing agencies and brand teams. It runs the full workflow: campaign brief →
AI-assisted discovery → explainable shortlist → approvals → deliverables → performance
→ and crucially, **learns from every campaign** so the next one is faster and better.

## The wedge (why now, why us)
Agencies today run discovery in spreadsheets and memory. When a creator drops out,
or a new brief lands, the team starts from zero. DiscoverDesk turns every past
approval, rejection and campaign outcome into **organisational intelligence** — the
compounding asset competitors can't copy, because it's built from *your* history.

## What exists today (working prototype)
A fully functional single-file web app (deployable to Netlify/Hostinger) with:
- Discovery requests, assignment workflow (Sales→Manager→Discovery routing), review
  rounds with approve/reject + feedback
- Roster (bulk import with integrity guards), Brand Sheets, Influencer 360 aggregation
- **Mission Control** command center (live KPIs, SLA countdowns, workload, health)
- **Discovery Search** (natural language — real AI when the endpoint is enabled, clean
  local fallback otherwise)
- **Shortlist Builder** (drag-to-group, match-scored), **Creator Comparison**,
  **Content Calendar** (deadlines + conflict detection)
- **Creator Health Score** and rule-based **Match** + **Replacement** engines
- Roles/permissions, protected owner account, audit trail, Supabase cloud mode,
  Meta/Sheets integration hooks, email notifications

This proves the workflow and the UX. It is the demo that gets the meeting.

## What's built and what's next (honest)
- ✅ Discovery cockpit, scoring, shortlisting, calendar — **done, rule-based**
- 🟡 Saved searches, knowledge library, more automation — incremental
- 🔴 The moat features — **AI brief understanding, Creator Intelligence Graph,
  Discovery Memory / Campaign Genome (learning), semantic search, campaign execution,
  client/creator portals, performance/ROI** — require the backend build. A Phase-1
  scaffold (Next.js + Supabase, multi-tenant with RLS, owner-lock as a DB trigger,
  keyset-paginated API for millions of rows) is included and ready to grow. A first
  real AI endpoint (`api/ai-search.js`) already turns plain English into filters.

## What we're building toward
Scale target: millions of creators, thousands of concurrent users, multi-tenant across
agencies and brands, with cross-brand sharing. Architecture and phasing are documented
(`ARCHITECTURE-AND-ROADMAP.md`). This is a team-and-quarters build, not a weekend — the
prototype de-risks the product; the raise/hire funds the platform.

## The ask (fill in for your context)
- **If raising:** seeking [₹__] to build Phase 1–2 (backend, multi-tenancy, search,
  first AI features) over [__] months with [__] engineers.
- **If hiring:** looking for a full-stack engineer (Next.js + Postgres/Supabase) to
  take the scaffold to a live multi-tenant product, starting with the Roster and
  Requests modules.

## Why it's defensible
The database tells you *who exists*. DiscoverDesk tells you *who to pick, why, who's
next-best, and what happened last time* — and it gets smarter with every campaign your
team runs. That compounding, company-specific intelligence is the durable moat.

---
*Prototype, architecture, roadmap and full feature-status breakdown are in the same
bundle. Everything marked 🔴 is scoped, not hand-waved.*

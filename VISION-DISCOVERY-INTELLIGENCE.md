# DiscoverDesk — Discovery Intelligence Platform (Vision Spec)

This captures the full product vision from your four vision documents, organised
and — importantly — tagged with what's real today versus what needs the platform
build. Nothing here is marketing fluff; every item is tagged so you (or a developer,
or an investor) can see exactly what exists and what's ahead.

**Legend**
- ✅ **BUILT** — shipped in `index.html` today (rule-based / UI, no ML)
- 🟡 **BUILDABLE** — can be added to the current file as rule-based logic
- 🔴 **PLATFORM** — needs the backend build (server, ML, vector DB, data feeds)

---

## The mission (kept verbatim from your docs)

> Enable any discovery manager to find the perfect creator in under 3 minutes with
> the highest possible confidence. Discover faster. Execute smarter. Measure better.

The product answers four questions better than anyone: **Who is the best creator?
Why? Who's the next best? How confident are we?**

---

## Module-by-module status

### 1. Discovery Command Center / Mission Control
✅ **BUILT.** Live KPIs (new, in-discovery, awaiting review, delivered, overdue,
SLA-risk, avg health), SLA countdown list, live activity feed, team-workload bars,
and a "requests needing attention" list sorted by health. It's the new home screen
under **Mission Control**.
🔴 Real-time push across 10k users, "AI recommendations today", client-satisfaction
metrics → PLATFORM (needs realtime infra + data you don't collect yet).

### 2. Universal / Natural-Language Search
🔴 **PLATFORM.** "Find premium fitness creators in Bangalore with 70% male audience
under ₹80K", "creators similar to X", "rejected by Nykaa but approved by Mamaearth"
— this is semantic search over embeddings + a vector database + real audience data.
Current app has fast keyword + filter search; the ChatGPT-style version is a backend
feature. (Roadmap Phase 2/4.)

### 3. AI Discovery Engine / Brain
🔴 **PLATFORM.** Reading a free-text brief and *understanding* budget/audience/tone/
competitors requires an LLM API called server-side, grounded in your data. Not
possible in a static file. This is the single biggest AI feature and the clearest
reason you need the backend.

### 4. Creator 360° Intelligence Profile
✅ **PARTIAL / BUILT.** The current profile already shows identity, audience
demographics, performance scores (quality/viral/consistency/authentic/fake/AI),
pricing, growth sparkline, collaborations and notes.
🟡 Match-fit and risk scores per creator are now computed (see Shortlist Builder).
🔴 Real audience income/interests/device data, growth *prediction*, lookalikes by
embedding → PLATFORM (needs a real data provider + ML).

### 5. Discovery Workspace (per-request)
✅ **PARTIAL.** Each request already has a detail view with rounds, decisions,
feedback, timeline and events.
🟡 Checklist, files, versions, client-feedback thread → BUILDABLE incrementally.

### 6. Smart Shortlist Builder
✅ **BUILT.** Drag-and-drop creators from the roster pool into groups: Perfect /
Strong / Budget / Premium / Backup / Risky / Rejected. Each card shows a live
match score and its top risk flag. Export the whole shortlist to Excel.

### 7. Creator Intelligence Network / Graph
🔴 **PLATFORM.** Audience-overlap %, similarity graph, "open one creator, discover
100" — needs a graph/vector layer and real audience data. This is your stated #1
differentiator and it is squarely a backend build. (Roadmap Phase 4.)

### 8. Discovery Memory / Genome
🔴 **PLATFORM.** "Learns which creators clients approved/rejected, best combinations,
winning shortlists" — a learning loop over historical outcomes = a data pipeline +
ML. The current app *stores* approvals/rejections/drop-rate (the raw material), but
it does not learn from them. (Roadmap Phase 4.)

### 9. Brand Intelligence
🟡 **PARTIALLY BUILDABLE.** Per-brand preferred budget / categories / approved
creators can be *aggregated* from history with rules (no ML). "Adapts recommendations
automatically" in the smart sense → PLATFORM.

### 10. Discovery Health Score
✅ **BUILT.** Every request gets a live 0–100 health score from brief-completeness,
progress, creator diversity, budget fit, risk level and backup availability. Shown
on Mission Control; the formula is transparent.

### 11. Discovery Analytics
✅ **PARTIAL.** Turnaround, workload, drop-rate, leaderboards already exist in
Reports/Team. 🟡 First-pass approval rate, search efficiency, seasonal demand →
BUILDABLE. 🔴 "AI effectiveness", predictive trends → PLATFORM.

### 12. AI Recommendation Engine (explainable)
🟡 **PARTIAL / BUILDABLE.** Match score already breaks down into audience / budget /
category / safety / performance / availability sub-scores with a confidence rating —
that *is* rule-based "why". 🔴 "Predict campaign success", "similar successful
campaigns" → PLATFORM (ML).

### 13. Discovery Knowledge Library
🟡 **BUILDABLE.** Saved searches, templates, playbooks, SOPs — all storable in the
current data model. Not yet built; low effort when you want it.

### 14. Bulk Discovery Engine
✅ **PARTIAL.** Import already handles up to 100k rows with dedupe, validation and
scoring. 🔴 "Find 10,000 creators across 18 categories and auto-build shortlists" in
one action → needs the search engine + queues (PLATFORM).

### 15. Admin & Permissions
✅ **BUILT.** Roles, per-user permissions, module visibility, the Sales→Manager→
Discovery assignment chain, the protected primary-owner account, download/export
permission, deactivate/delete with guards, audit trail.

---

## The bigger-scope docs (Campaign Execution, Portals, Live Market)

These appear in your "DiscoverDesk X" and "Bloomberg Terminal" docs. All 🔴 PLATFORM:

- **Campaign execution** (outreach → negotiation → contracts → content review →
  publishing → payments) — each is its own product surface; several are full products.
- **Client portal / Creator portal** — separate authenticated apps.
- **Communication hub** (WhatsApp/email/calls history) — integrations + storage.
- **Live Market / creators-as-stocks** — needs a real-time data provider feed.
- **One-click AI client decks** — LLM generation server-side (PowerPoint export
  exists as a manual path; the *AI-written* version is backend).
- **Content review, deliverable tracking, performance/ROI** — needs live campaign
  data flowing in from the platforms.

None of these are "add to the file" — they're the reason the roadmap exists.

---

## What shipped today (this build)

Real, in `index.html`, rule-based and honest:

1. **Mission Control** home — the command center from doc #3, with live KPIs, SLA
   countdowns, activity feed, team workload, and health-sorted attention list.
2. **Shortlist Builder** — drag-to-group with live match scores and risk flags.
3. **Creator Comparison** — up to 4 creators side by side across 11 metrics.
4. **Discovery intelligence engine** — `matchScore()`, `riskFlags()`, `healthScore()`:
   transparent formulas over your existing data. Explainable, not ML.

Plus everything from prior builds (assignment chain, owner lock, import guards,
tool-aware chatbot, 15 module groups, fixed layering, 9-reel portfolios).

## The honest headline

The current app is now a **strong rule-based discovery cockpit**. The vision docs
describe an **AI intelligence platform**. The gap between them is the ML + backend +
data-feed work in `ARCHITECTURE-AND-ROADMAP.md`. Everything marked 🔴 lives there.
Build it in phases, feed each phase real data, and this vision is reachable — over
quarters and a team, not one file and one night.


---

# APPENDIX: The "7 Pillars / DiscoverDesk X" vision (doc #6)

Your latest doc reorganises everything into 7 pillars and 7 trademarked USPs. Same
honest tagging applies. Nothing below changes the build reality — it's a cleaner
way to *describe* the same destination.

## The 7 pillars → status
1. **Discovery** — search, filters, saved searches, shortlists, duplicate detection,
   backup suggestions. ✅ Mostly BUILT (Discovery Search, Shortlist Builder, dedupe,
   rule-based replacement). 🔴 Reverse/audience/competitor semantic search = backend.
2. **Creator Intelligence** — the 360° profile. ✅ Identity, audience, performance,
   commercial, scores BUILT. ✅ Creator Health Score™ now BUILT (standing index).
   🔴 WhatsApp/call history, growth *prediction*, lookalikes = backend.
3. **Campaign Operating System** — brief→discovery→contracts→deliverables→payments→
   reports. 🔴 PLATFORM. This is a full product surface; several sub-parts are their
   own products.
4. **Content Operations** — deliverable tracking through publish. 🔴 PLATFORM.
5. **Performance Intelligence** — ROI/CPM/CPA/… + AI explanations. 🔴 PLATFORM
   (needs live campaign data feeds + ML).
6. **Automation** — auto-assign, reminders, escalation, reports, invoices. 🟡 Some
   (auto-assign rules, reminders) BUILDABLE; most need the backend + a scheduler.
7. **DiscoverDesk AI** — one assistant for everything. 🟡 The tool-aware chatbot is
   BUILT; 🔴 the "find creators / predict ROI / build deck / replace creator" natural-
   language actions need the AI backend (the ai-search endpoint is the first real step).

## The 7 USPs (™) → status
- **Creator Intelligence Graph™** 🔴 — graph + audience-overlap data. Backend.
- **Discovery Memory™** 🔴 — learning loop over outcomes. Backend + ML.
- **Campaign Genome™** 🔴 — same, campaign-level. Backend + ML.
- **Creator Health Score™** ✅ **BUILT** — standing per-creator 0–100 index from
  engagement, authenticity, consistency, safety, growth, activity, price stability,
  response. Shown in search results and comparison.
- **AI Replacement Engine™** 🟡 **PARTIAL/BUILT** — rule-based version shipped
  ("Find replacement" on any creator: closest by category, follower band, price,
  city, engagement). The "similar audience/style" version is 🔴 backend.
- **Campaign War Room™** 🟡 — Mission Control is the discovery-side version (BUILT);
  the campaign-execution war room is 🔴 backend.
- **Discovery Genome™** 🔴 — organisational learning graph. The flagship; it is the
  clearest reason the platform build exists.

## The first real AI step is shipped
`api/ai-search.js` is a working serverless endpoint: it sends a plain-English query
to a model and returns structured filters the app applies. Deploy it on Vercel, set
`ANTHROPIC_API_KEY`, flip `settings.ai.enabled`, and Discovery Search becomes true
natural language. Without it, the app falls back to transparent local parsing — so
it works either way, honestly labelled in the UI.

## And the backend is scaffolded
`backend-starter/` is a real Next.js + Supabase Phase-1 skeleton: multi-tenant schema
with Row-Level Security, the owner-lock enforced as a DB trigger, and a keyset-
paginated creators API built to hold millions of rows. That's the foundation every
🔴 feature above gets built on — see its README for the migration order.


---

# APPENDIX 2: "Enterprise / DiscoverDesk AI" vision (doc #7)

Doc #7 is the cleanest articulation of the same platform (15 sections + 7 ™ USPs +
future roadmap). It introduces **no new buildable-in-file features** beyond what's
already shipped or scaffolded — it's the enterprise framing for fundraising/hiring,
which is exactly what ONE-PAGER.md is for.

Net-new buildable item from doc #7, now shipped: **Content Calendar** ✅ — request
deadlines + campaign dates on a month grid, with conflict detection (3+ deadlines on
a day flags as overload). Everything else in doc #7 maps to items already tagged
above: Campaign Management / Deliverables / Performance Center / Client & Creator
Portals / platform-API integrations = 🔴 PLATFORM; AI Copilot = 🟡 (chatbot built,
NL actions need the AI backend); the 7 USPs = as tagged in Appendix 1.

**This is the fifth vision doc. They describe one product.** Further vision docs won't
change the build — the backend build will. The prototype is now a strong operator tool
you can use today; the moat features are scoped in the roadmap and started in
`backend-starter/`. That's the honest state of things.

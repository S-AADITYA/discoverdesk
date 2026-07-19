# DiscoverDesk — Backend Starter (Phase 1)

This is the **real backend scaffold** from the roadmap — Next.js + Supabase (Postgres)
with multi-tenant Row-Level Security. It ports the highest-value, highest-volume
module (Roster) to a proper database so you can grow past the single-file ceiling.

This is a *starting skeleton*, not the finished platform. It gives you:
- A Next.js app that deploys to Netlify/Vercel with CI/CD
- A Postgres schema with `tenant_id` on every row + RLS (the multi-tenant core)
- A paginated, indexed creators API (handles millions of rows the right way)
- The auth + permission shape ported from your current app

## Run it
```bash
npm install
cp .env.example .env.local   # fill in Supabase keys
npm run dev
```

## Deploy (CI/CD)
1. Push this folder to a GitHub repo.
2. Connect the repo in Netlify or Vercel → every push to main auto-deploys.
3. Preview deploys run on every pull request.
4. Add env vars (Supabase URL/keys, ANTHROPIC_API_KEY) in the host dashboard.

## Migration order (from the roadmap)
1. **Roster** (this starter) — highest volume, do it first.
2. Requests + rounds + decisions.
3. Brand sheets, Influencer 360 aggregation (as a DB view/materialized view).
4. Auth + permissions server-side (the assignment chain + owner lock become DB constraints).
5. Search engine (Typesense/pgvector) for the natural-language + semantic features.
6. AI endpoints (brief understanding, match scoring, replacement) as serverless functions.

The current single-file app stays as your working prototype and design reference
while this is built out module by module.

## Next module to port (Requests + auth) — your immediate next step
After Roster, port Requests + rounds + decisions and wire real auth:
- `requests` table (tenant_id, brand, niche, budget, deadline, status, assignee_id)
- `rounds` + `decisions` tables (creator picks per round, approve/reject + reason)
- Supabase Auth for login; the Sales→Manager→Discovery routing and the owner-lock
  become **server-side** checks / DB constraints (never trust the browser).
Ask your developer (or me, in a repo) to scaffold these next — the Roster route here
is the pattern to copy.

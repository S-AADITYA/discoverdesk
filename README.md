# DiscoverDesk

An influencer-discovery operations app for agencies. Sales & KAM log enquiries and raise requests, Discovery delivers a profile sheet per campaign, requesters approve or reject influencers one-by-one across rounds, and everyone shares live reports, dashboards, exports and email alerts.

## What's in this folder
- `index.html` — the whole app (one file; runs in any browser).
- `api/notify.js` — Vercel serverless function that sends email via Resend.
- `supabase-schema.sql` — creates the database, secure logins, and per-user rules.
- `DEPLOY.md` — step-by-step to put it online for your team (start here).
- `HOW-TO-USE.md` — plain-English guide to using the app day to day.

## Two ways to run it
1. **Local (instant):** just open `index.html`. Data saves on that one device. Good for a quick look.
2. **Live for the team (recommended):** follow `DEPLOY.md`. You get real encrypted logins, one shared cloud database, auto emails, and a public link your whole team uses from anywhere.

## Tech (for whoever helps you deploy)
- Static frontend (vanilla JS) + SheetJS for Excel import/export.
- Supabase: Postgres + Auth (encrypted passwords) + Row-Level Security + Realtime.
- Data model kept in clean pieces (profiles, brands, campaigns, requests+rounds, influencers, enquiries, notifications, activity) so other apps/CRMs can connect later via Supabase's API.
- Email via a Vercel serverless function calling Resend (secret key stays server-side).

The first person to sign up becomes the permanent admin; everyone else is admin-approved. There is no auto-logout, and every change is saved to the cloud immediately.

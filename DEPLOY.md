# Deploy DiscoverDesk — live app for your whole team

> **Stack for this deployment: Vercel + Supabase only.** Everything — the app
> UI (`index.html`) *and* the `api/` functions — lives in one Vercel project.
> `HOSTINGER-DEPLOY.md` and the Netlify config (`netlify.toml`) describe a
> different, split setup (UI on a separate static host, functions on Vercel).
> You don't need either of those files — ignore them. Keep `CFG.API_BASE`
> in `index.html` set to `''` (empty); same-origin means no CORS config needed.

Follow these once. It's free. No coding — just copy/paste. About 20 minutes.

You'll set up three free things:
- **Supabase** = the database + secure logins (encrypted passwords)
- **Resend** = sends the emails
- **Vercel** = puts the app online so your team can open it from anywhere — UI and API together

Keep this page open and do the steps in order.

---

## PART A — Database & logins (Supabase)

**A1.** Go to **supabase.com** → sign up (free) → **New project**. Pick a name, set a database password (save it), choose a nearby region, create. Wait ~2 minutes.

**A2.** Left menu → **SQL Editor** → open our file **supabase-schema.sql**, copy everything, paste, click **Run**. You should see "Success". (If one line about "publication" says it already exists, ignore it.)

> Only doing basic team/auth/data features? `supabase-schema.sql` is all you need.
> Planning to use the Roster scale-pack (millions of influencers, Sheets sync,
> auto-refresh — see `ROSTER-SCALE.md`)? Also run **supabase-roster-schema.sql**
> here before moving on.

**A3. Turn off email confirmation** (so people can log in right after signing up):
- Left menu → **Authentication** → **Providers** (or **Sign In / Up**) → **Email**.
- Turn **OFF** "Confirm email". Save.

**A4. Copy your two keys:** left menu → **Project Settings → API**. Copy:
- **Project URL** (like `https://abcd1234.supabase.co`)
- **anon public** key (long string)

---

## PART B — Put your keys in the app

**B1.** Open **index.html** in any text editor (Notepad / TextEdit / VS Code).

**B2.** Near the top, find:
```
const CFG={ SUPABASE_URL:'', SUPABASE_ANON_KEY:'', API_BASE:'' };
```
Paste your Supabase values inside the quotes, and **leave `API_BASE` empty**
(the app and its `api/` functions live in the same Vercel project, so no
separate API URL is needed):
```
const CFG={ SUPABASE_URL:'https://abcd1234.supabase.co', SUPABASE_ANON_KEY:'eyJ...long...key', API_BASE:'' };
```
Save the file.

---

## PART C — Email sending (Resend)

**C1.** Go to **resend.com** → sign up (free) → **API Keys** → **Create API Key** → copy it (starts with `re_`).
- To start, you can send from Resend's test address `onboarding@resend.dev`. Later, add your own domain in Resend for branded email.

You'll paste this key into Vercel in Part D (not into the app file — it stays secret on the server).

---

## PART D — Put it online (GitHub → Vercel)

**D1. Upload to GitHub:**
- Go to **github.com** → sign up/in → **New repository** → name it `discoverdesk` → Create.
- On the new repo page click **uploading an existing file**.
- Drag in **everything from the `discoverdesk-app` folder**, keeping the `api` folder as a folder. At minimum you need:
  - `index.html`
  - `package.json`  (tells Vercel to install the packages the `api/` functions need — don't skip this)
  - `vercel.json`
  - `api/` (the whole folder, all 7 files inside it)
  - `supabase-schema.sql`, `DEPLOY.md`, `README.md` (optional but nice to keep)
  - Only using the Roster scale-pack? Also include `supabase-roster-schema.sql` and `ROSTER-SCALE.md`.
- Click **Commit changes**.

**D2. Deploy on Vercel:**
- Go to **vercel.com** → sign up with your **GitHub** account.
- **Add New → Project** → **Import** your `discoverdesk` repo.
- Before clicking Deploy, open **Environment Variables** and add:
  - Name `RESEND_API_KEY` → Value = the `re_...` key from Resend
  - Name `EMAIL_FROM` → Value = `DiscoverDesk <onboarding@resend.dev>`
  - Using the Roster scale-pack? Also add `SUPABASE_SERVICE_KEY` (Project Settings → API → `service_role` key — **not** the anon key), plus `GOOGLE_SA_EMAIL` / `GOOGLE_SA_KEY` / `SHEET_ID` / `SHEET_RANGE` and `PROVIDER_BASE_URL` / `PROVIDER_API_KEY` if you're using those. See `ROSTER-SCALE.md`.
- Click **Deploy**. Wait ~1 minute. You get a link like `https://discoverdesk.vercel.app`.

---

## PART E — First login = you, the admin

**E1.** Open your Vercel link. The top pill should say **"Live · Cloud"** (green).

**E2.** Click **Request access**, enter your name/email/password, pick any department, submit.
- Because you're the **first** person, you're automatically made the **permanent Admin** and logged straight in.

**E3.** Your team opens the same link → **Request access** → picks their department.
- You approve them in **People & Access**. Done — they can log in from anywhere.

---

## You now have a real live app
- **Encrypted logins** (Supabase Auth) — you never store raw passwords.
- **Shared live database** — everyone sees the same data, updates within seconds.
- **Nothing lost** — every action is saved to the cloud instantly; you can also **Download full backup** in People & Access.
- **No auto-logout** — people stay signed in on their device.
- **Auto emails** — assignments, submissions and decisions email people automatically (they can adjust which, in Inbox → Email settings).

## Optional: connect Meta / Instagram (live follower data)
This lets you pull live follower/media counts onto influencers.
1. At **developers.facebook.com**, create an app, add **Instagram Graph API**, and connect an Instagram **Business/Creator** account (linked to a Facebook Page).
2. Generate an access token with `instagram_basic` + `instagram_manage_insights`, and note your **IG Business account ID**.
3. In the app, go to **Integrations → Meta**, paste the token + IG account ID, Save, then **Test connection**.
4. On any influencer row, click the ✦ button to enrich it from Meta. (The `api/meta.js` function handles this server-side.)

## Optional: connect Slack / Zapier / Make / Teams (event webhooks)
Push every event (request raised, sheet submitted, round approved/rejected) into your other tools.
1. Get an **Incoming Webhook URL** from Slack, a **Catch Hook** from Zapier, a scenario URL from Make, or a Teams connector URL.
2. In the app go to **Integrations → Outbound webhook**, paste the URL, **Save**, then **Send test event**.
3. The `api/webhook.js` function forwards events server-side (so browser CORS never blocks it). From there, Zapier/Make can route to 6000+ apps (Google Sheets, Notion, HubSpot, WhatsApp, etc.).

## Making changes later
- Edited `index.html`? Re-upload it to GitHub; Vercel redeploys automatically.
- Want branded email (from `you@yourbrand.com`)? Add + verify your domain in Resend, then change the `EMAIL_FROM` value in Vercel.

## Troubleshooting
- Pill still "Local only": your keys in `index.html` (Part B) are missing or have a typo.
- Login says profile not found: make sure you ran the schema (A2) and turned off email confirmation (A3).
- No emails arriving: check `RESEND_API_KEY` is set in Vercel (Part D2); check spam; the free test sender only reaches your own verified Resend email until you add a domain.
- Locked out / want to start over: in Supabase → Table Editor you can clear the `kv` and `profiles` tables; the next signup becomes admin again.

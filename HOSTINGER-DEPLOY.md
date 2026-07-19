# Deploying DiscoverDesk on Hostinger (discovery-desk.myhaulstore.in)

## 0. FIRST — rotate that FTP password
The FTP password was shared in a chat message, so treat it as public.
hPanel → **Files → FTP Accounts → Change password**. Do the same for hPanel login if it was shared.
Never paste FTP/hosting passwords into chats, tickets, or AI tools.

## 1. What can and cannot run on Hostinger shared hosting
| Piece | Hostinger shared (Linux) | Notes |
|---|---|---|
| `index.html` (the whole app UI) | ✅ Works | It's a single static file |
| Supabase (login, shared data, realtime) | ✅ Works | Browser talks to Supabase directly |
| `api/*.js` (notify, meta, webhook, sheets-sync, provider-refresh, roster-search) | ❌ Does NOT run | These are **Node serverless functions**. Shared Linux hosting runs PHP, not Node. |
| Cron (8-hour provider refresh, 30-min Sheets sync) | ❌ Not from these files | Same reason |

**So use both:** UI on Hostinger, functions stay on Vercel. The app supports this.

## 2. Point the app at your Vercel functions
Open `index.html`, find near the top:

```js
const CFG={ SUPABASE_URL:'', SUPABASE_ANON_KEY:'',
  API_BASE:'' };
```

Set:
```js
const CFG={
  SUPABASE_URL:'https://YOURPROJECT.supabase.co',
  SUPABASE_ANON_KEY:'eyJ...your anon key...',
  API_BASE:'https://discoverdesk.vercel.app'   // where api/ is deployed
};
```
Now Sheets sync, Meta enrich, webhooks and email all work from the Hostinger site.

> The Vercel project must allow the calls. The functions already send
> `Access-Control-Allow-Origin: *`. If you tighten it later, allow
> `https://discovery-desk.myhaulstore.in`.

## 3. Upload — WITHOUT touching your other sites
Other sites are live on this account, so **do not upload into the main `public_html` root**
and **do not delete anything**.

Your subdomain has its own folder. Via FTP (FileZilla) or hPanel → File Manager:

1. Connect to host `82.25.125.159` with the FTP user.
2. Find the folder for **discovery-desk.myhaulstore.in** — usually:
   - `/home/uXXXXXXXXX/domains/myhaulstore.in/public_html/discovery-desk/`, or
   - `/public_html/discovery-desk/`
   (In hPanel → **Websites → discovery-desk.myhaulstore.in → Dashboard**, the
   "Document root" field tells you the exact path. Trust that field.)
3. Upload **only** `index.html` into that folder.
4. Overwrite the existing `index.html` when asked. Touch nothing else.

That's it — https://discovery-desk.myhaulstore.in/ serves the new build.

## 4. Optional hardening (recommended)
Create a `.htaccess` next to `index.html`:

```apache
# Force HTTPS
RewriteEngine On
RewriteCond %{HTTPS} off
RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]

# Basic security headers
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set Referrer-Policy "strict-origin-when-cross-origin"

# Don't cache the app shell (so redeploys show up instantly)
<FilesMatch "index\.html$">
  Header set Cache-Control "no-cache, must-revalidate"
</FilesMatch>
```

## 5. Checklist after upload
- [ ] Site loads at https://discovery-desk.myhaulstore.in/
- [ ] Login works (Supabase configured) or demo loads
- [ ] Integrations → "Sync now" reaches your Vercel API (check browser console for CORS)
- [ ] Other sites on the account still load — nothing was overwritten

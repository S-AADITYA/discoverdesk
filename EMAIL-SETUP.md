# DiscoverDesk — Email setup (Gmail via service account)

Everything below is filled in with the real values. Two people do two small
tasks. ~10 minutes total.

--------------------------------------------------------------------
## PART 1 — Google Workspace admin (admin.google.com + Cloud Console)
--------------------------------------------------------------------

### 1a. Enable the Gmail API (one click)
Open this link (already points at the right project) and click **ENABLE**:
https://console.developers.google.com/apis/api/gmail.googleapis.com/overview?project=95589488720

### 1b. Authorize the service account to send mail (Domain-wide delegation)
1. Go to **admin.google.com**
2. **Security → Access and data control → API controls → Domain-wide delegation**
   → **Manage Domain-Wide Delegation** → **Add new**
3. Paste these two values exactly:

   **Client ID:**
   ```
   107406094471061637279
   ```

   **OAuth scopes:**
   ```
   https://www.googleapis.com/auth/gmail.send
   ```
4. Click **Authorize**.

### 1c. Confirm the "from" mailbox exists
Emails will be sent **from** a real mailbox in your Workspace. Decide which one
(e.g. `notifications@myhaulstore.com` or any existing licensed user). It must be
a real, active mailbox in the myhaulstore.com Workspace.

Reference (nothing to change here):
- Service account: `discoverdesk-sync@discoverdesk.iam.gserviceaccount.com`
- Google Cloud project: `discoverdesk` (number 95589488720)

--------------------------------------------------------------------
## PART 2 — Whoever manages Vercel (the app hosting)
--------------------------------------------------------------------

1. **vercel.com** → project **discoverdesk** → **Settings → Environment Variables**
2. Add ONE new variable (for Production):

   | Name           | Value                                   |
   |----------------|-----------------------------------------|
   | `GMAIL_SENDER` | the mailbox from step 1c, e.g. `notifications@myhaulstore.com` |

3. Confirm these two already exist there (they do — Sheets sync uses them):
   `GOOGLE_SA_EMAIL`, `GOOGLE_SA_KEY`
4. **Deployments → ⋯ → Redeploy** (so the new variable takes effect).

--------------------------------------------------------------------
## Done
--------------------------------------------------------------------
After Part 1 + Part 2, DiscoverDesk sends real email automatically on
assignments, submissions, decisions, reminders and escalations — from your
GMAIL_SENDER mailbox. Each person controls which emails they receive under
**Inbox → Email settings**.

If a test send fails, the usual cause is that step 1b (delegation) hasn't
propagated yet — give it a few minutes and retry.

# Azure deployment — `Azure-deploy` branch

This branch runs on **Azure Static Web Apps** *and* still runs on Vercel.
Nothing that existed before was modified — only these files were added:

| File | Purpose |
|---|---|
| `staticwebapp.config.json` | SWA routing, Node 20 runtime, headers |
| `api/host.json` | Azure Functions host config |
| `api/package.json` | Functions deps + `main` entry point |
| `api/_azure/shim.js` | Adapts the Vercel `(req,res)` handlers to Azure |
| `api/_azure/routes.js` | Registers `/api/ask-hary`, `/api/forgot-password`, `/api/send-report-email` |
| `api/.funcignore` | Keeps docs out of the Functions package |
| `.vercelignore` | Hides the Azure files from Vercel |
| `.github/workflows/azure-static-web-apps.yml` | Deploys on push to `Azure-deploy` |

**`index.html`, `vercel.json`, `package.json` and all three API handlers are byte-identical
to `main`.** The handlers were not forked, so a bug fixed on `main` is fixed on both
deployments after a merge — you never fix the same thing twice.

---

## Why the shim exists

The handlers are written for Vercel:

```js
module.exports = async (req, res) => { res.status(200).json({ ok: true }); };
```

Azure Functions v4 calls `async (request, context)` and expects the response to be
**returned**. `api/_azure/shim.js` fakes the `req`/`res` pair the handlers expect and
translates the result back. Verified: all three routes return the same status code and
the same response body on both platforms.

---

## Deployment steps

### 1. Push the branch

```bash
git checkout -b Azure-deploy
# copy this folder's contents over your working tree
git add -A
git commit -m "Add Azure Static Web Apps deployment (additive; Vercel unaffected)"
git push -u origin Azure-deploy
```

### 2. Create the Static Web App

Azure Portal → **Create a resource** → **Static Web App**.

| Field | Value |
|---|---|
| Subscription | Azure for Students |
| Resource group | create `rg-viesl-report-analyzer` |
| Name | `viesl-report-analyzer` |
| Plan type | **Free** |
| Region | Central India (or East Asia) |
| Deployment source | **Other** |

> Choose **Other**, not GitHub. If you pick GitHub, the portal commits a *second*
> workflow file and both would deploy on every push.

Click **Review + create**.

### 3. Wire up GitHub

1. In the new Static Web App → **Overview** → **Manage deployment token** → copy it.
2. GitHub repo → **Settings → Secrets and variables → Actions → New repository secret**
   - Name: `AZURE_STATIC_WEB_APPS_API_TOKEN`
   - Value: the token
3. GitHub → **Actions** tab → run the *Azure Static Web Apps CI/CD* workflow
   (or just push any commit to `Azure-deploy`).

Your URL appears on the Overview page as
`https://<generated-name>.<region>.azurestaticapps.net`.

### 4. Application settings (environment variables)

Static Web App → **Settings → Environment variables** → add each one.
These are *not* inherited from Vercel.

| Variable | Value |
|---|---|
| `SUPABASE_URL` | same as Vercel |
| `SUPABASE_ANON_KEY` | same as Vercel |
| `SUPABASE_SERVICE_KEY` | **the `service_role` key** — see warning below |
| `MAIL_SECRET` | same as Vercel |
| `MAIL_FROM` | same as Vercel |
| `GMAIL_USER` | same as Vercel |
| `GMAIL_APP_PASSWORD` | same as Vercel (no spaces) |
| `RESEND_API_KEY` | same as Vercel (if used) |
| `GEMINI_KEY` | same as Vercel |
| `GEMINI_MODEL` | same as Vercel |
| `APP_VERSION` | `VR 8.1` |
| `PORTAL_URL` | **the Azure URL, not the Vercel one** |

Save, then wait for the app to restart (about a minute).

### 5. Verify, in this order

1. Open the Azure URL — the login page should load.
2. Log in with an existing account (same Supabase, same users).
3. Open any report and upload a dump — this is pure client-side, so it proves the static hosting.
4. **Forgot password → send OTP.** This is the canary: it exercises `/api/forgot-password`,
   the Supabase service key and outbound SMTP in one go.
5. Ask Hary something — exercises `/api/ask-hary`.
6. Leave scheduled email alone until you've read the warning below.

---

## Warnings specific to this app

### `SUPABASE_SERVICE_KEY` is currently wrong on Vercel

From earlier debugging, the value in Vercel holds the **anon / publishable** key, not the
`service_role` key. That is why OTP mail fails. Put the real `service_role` key into Azure
(Supabase → Project Settings → API → `service_role`), and fix Vercel at the same time.

### Do not let both deployments send scheduled emails

Your `pg_cron` job in Supabase posts to one absolute URL. If you ever point it at both
Vercel and Azure, **every recipient gets two copies of every report**. Pick one platform
as the mailer and leave the other's `/api/send-report-email` unused.

### 45-second timeout

SWA managed functions cap each request at **45 seconds**. Your `vercel.json` allows
`send-report-email` up to **60 seconds**. If a large "send now" currently runs longer than
45 s it will fail on Azure. Time your biggest schedule before relying on it.
`ask-hary` (30 s) and `forgot-password` (20 s) are comfortably inside the cap.

### Both sites share one database

Users, sessions, the audit log and uploaded files are the same on both URLs. That is
usually what you want — just remember a change made on one is visible on the other.
If you have restricted redirect URLs in Supabase → Authentication, add the Azure domain.

### Free-plan limits

100 GB bandwidth/month, 250 MB per environment, 2 custom domains, no SLA. This app is
13 MB / 22 files, so only bandwidth is worth watching — `images/background.mp4` is
10.5 MB of every cold page load.

---

## Keeping the branches in sync

Always fix on `main` first, then merge forward:

```bash
git checkout main
# ...make the fix, test, commit, push...

git checkout Azure-deploy
git merge main          # conflict-free: this branch only ADDS files
git push
```

Because `Azure-deploy` never modifies a file that `main` owns, the merge is clean.
Do **not** edit `index.html` or the API handlers directly on `Azure-deploy`.

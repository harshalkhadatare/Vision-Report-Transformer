# Report Email Notifications — setup

Admin creates schedules in **Admin → Email Alerts**: pick the reports, pick the
recipients, set the time and days, write a description. Supabase `pg_cron` wakes
every 5 minutes, finds anything due, and a Vercel function sends the mail through
Resend (free tier: 100/day, 3,000/month).

The email contains: recipient's name, the description, each selected report with
its **last-updated date/time and who uploaded it**, and a button that opens the
portal.

---

## 1. Run the SQL

Open Supabase → SQL Editor → paste and run **`supabase_setup.sql`**.
It is idempotent — safe to run on the live database.

This adds:
- `email` column on `app_users` (+ the admin UI to fill it in)
- `email_schedules` and `email_log` tables
- the admin RPCs and the `email_dispatch_due()` job

## 2. Get a Resend API key

1. Sign up at **resend.com** (no card needed)
2. **API Keys → Create** → copy it

Until `visioninfraindia.com` is verified you can only send to **your own**
Resend account address — that is Resend's anti-abuse rule, not a bug. Use
**Send test** to yourself in the meantime.

## 3. Vercel environment variables

Project → **Settings → Environment Variables**:

| Name | Value |
|---|---|
| `RESEND_API_KEY` | from step 2 |
| `SUPABASE_URL` | `https://tytzjbvmjtdfxfvftigq.supabase.co` |
| `SUPABASE_SERVICE_KEY` | Supabase → Settings → API → **service_role** key |
| `MAIL_SECRET` | any long random string (you choose it) |
| `PORTAL_URL` | `https://your-app.vercel.app` |
| `MAIL_FROM` | *(later)* `VIESL Reports <reports@visioninfraindia.com>` |

⚠️ The **service_role** key bypasses row-level security. It lives only in Vercel
env vars — never in the browser, never in the repo.

Then **redeploy** (env vars only apply to new deployments).

## 4. Turn on the scheduler

Back in the Supabase SQL Editor, run these two lines with your own values:

```sql
alter database postgres set app.mail_endpoint = 'https://your-app.vercel.app/api/send-report-email';
alter database postgres set app.mail_secret   = 'the-same-string-as-MAIL_SECRET';
```

Then run the `create extension` / `cron.schedule` block at the bottom of
`supabase_setup.sql`. Check it registered:

```sql
select jobname, schedule, active from cron.job;
```

## 5. Add email addresses

**Admin → Users** → *Add email* on each person. Anyone without one shows
**⚠ not set** and cannot be selected as a recipient.

## 6. Create a schedule

**Admin → Email Alerts → + New schedule.** Use **Send test** to check the
formatting before enabling it.

---

## Verifying your domain (to send to everyone)

Add Resend's three DNS records **wherever your DNS is actually served**.
Note: `visioninfraindia.com` currently resolves to `kyle.ns.cloudflare.com` /
`oaklyn.ns.cloudflare.com` — if those are not the nameservers your own Cloudflare
account shows, the zone lives on **another account** (likely your web host's) and
the records must be added there. Records added to an inactive zone do nothing.

Once verified, set `MAIL_FROM` and redeploy.

---

## Notes and limits

- **Times are IST** (`Asia/Kolkata`), 24-hour.
- **Granularity is 5 minutes** — a 09:00 schedule sends between 09:00 and 09:04.
- **One send per schedule per day**, guarded by `last_sent_at`, so a slow response
  cannot double-send on the next tick.
- **No attachments.** The email links to the portal instead (your Option B).
  Report files are built in the browser, so a server-side job cannot generate
  them — and links avoid the ~25 MB attachment limits entirely.
- **Every send is logged** to `email_log` and shown under *Recent sends*, including
  failures, so a silent failure is visible.
- Recipients without an email, or not `approved`, are skipped automatically and the
  run is logged as `skipped` rather than failing.

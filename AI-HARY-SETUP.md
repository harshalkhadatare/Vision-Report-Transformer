# Hary AI mode — setup (FREE)

Hary now has an **AI toggle** in its chat header. When ON, questions are answered by
Google Gemini using the **report you currently have open** (KPIs + a sample of rows).
When OFF, it uses the original instant, offline rule‑based answers.

Everything is free: Gemini's free tier + Vercel's free serverless functions.
Your API key stays hidden on the server (never in the browser).

---

## 1. Get a free Gemini API key
1. Open **https://aistudio.google.com/app/apikey**
2. Sign in with a Google account → **Create API key** → copy it.
   (No credit card, no billing.)

## 2. Add the key to Vercel
In your Vercel project: **Settings → Environment Variables → Add**
| Name | Value |
|------|-------|
| `GEMINI_KEY` | *(paste the key from step 1)* |

Apply it to **Production** (and Preview if you use it), then **redeploy**.

### (Optional) Only allow logged‑in users to use AI
Add these two as well, and Hary will verify the user's session before answering:
| Name | Value |
|------|-------|
| `SUPABASE_URL` | `https://tytzjbvmjtdfxfvftigq.supabase.co` |
| `SUPABASE_ANON_KEY` | *(your Supabase anon/public key)* |

## 3. Deploy
Push the project (this folder) to Vercel as usual. The file **`api/ask-hary.js`**
is automatically detected as a serverless function — no build step, no npm install.

## 4. Use it
Open the app → click the **Hary** bubble → flip the **AI** switch in the header →
open a report → ask things like:
- "Summarise this report in 3 bullets"
- "Which site earned the most?"
- "Total diesel issued this month"
- "Top 5 assets by value"

---

## Notes & honest caveats
- **Free‑tier limits:** Gemini free allows roughly 15 requests/minute. Fine for a small
  team; if many people ask at once, some requests briefly wait (you'll see a "busy" message).
- **What is sent:** the current report's **KPIs + up to 60 rows** of the on‑screen view are
  sent to Google to answer the question. Totals come from the (exact) KPIs; the row sample is
  for detail questions. If your data is confidential, review Google's API terms, or keep AI mode
  for aggregated questions only.
- **Accuracy:** the model is instructed to use KPI values for totals and to say when something
  isn't in the data, which avoids most made‑up numbers — but always sanity‑check critical figures.
- **Offline / local file:** AI mode needs the Vercel deployment + internet. If it can't reach the
  API, Hary automatically falls back to its built‑in answers.
- **Change the model:** edit `GEMINI_MODEL` in `api/ask-hary.js` (e.g. to `gemini-1.5-pro`).

// ============================================================================
//  Hary AI  —  Vercel serverless function (FREE tier)
//  Browser (Hary)  ->  /api/ask-hary  ->  Google Gemini API  ->  answer
//
//  It keeps your API key hidden on the server and answers ONLY from the
//  report data the browser sends (KPIs + a sample of the current view).
//
//  REQUIRED environment variable (set in Vercel > Settings > Environment Variables):
//     GEMINI_KEY            your free key from https://aistudio.google.com/app/apikey
//
//  OPTIONAL (only if you also want to block non-logged-in users):
//     SUPABASE_URL          e.g. https://tytzjbvmjtdfxfvftigq.supabase.co
//     SUPABASE_ANON_KEY     your Supabase anon/public key
//  If both are set, the caller's session token is verified before answering.
//
//  No npm packages needed — uses the built-in fetch (Node 18+ on Vercel).
// ============================================================================

const GEMINI_MODEL = 'gemini-1.5-flash'; // fast + free; change to gemini-1.5-pro if you prefer

module.exports = async (req, res) => {
  if (req.method === 'OPTIONS') { res.status(204).end(); return; }
  if (req.method !== 'POST') { res.status(405).json({ ok: false, error: 'Method not allowed.' }); return; }

  const KEY = process.env.GEMINI_KEY;
  if (!KEY) { res.status(500).json({ ok: false, error: 'Server is missing GEMINI_KEY. Add it in Vercel > Settings > Environment Variables.' }); return; }

  // Vercel auto-parses JSON bodies; fall back to manual parse just in case.
  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { body = {}; } }
  const question = (body && body.question ? String(body.question) : '').slice(0, 2000).trim();
  const summary = body && body.dataSummary ? body.dataSummary : null;
  const token = body && body.token ? String(body.token) : null;

  if (!question) { res.status(400).json({ ok: false, error: 'No question provided.' }); return; }

  // ---- optional: verify the Supabase session token ----
  const SB_URL = process.env.SUPABASE_URL;
  const SB_ANON = process.env.SUPABASE_ANON_KEY;
  if (SB_URL && SB_ANON) {
    try {
      const vr = await fetch(SB_URL.replace(/\/$/, '') + '/rest/v1/rpc/whoami', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'apikey': SB_ANON, 'Authorization': 'Bearer ' + SB_ANON },
        body: JSON.stringify({ p_token: token })
      });
      const who = await vr.json();
      if (!who || who.ok !== true) { res.status(401).json({ ok: false, error: 'Please sign in again to use AI mode.' }); return; }
    } catch (e) { /* if verification endpoint is unreachable, fail open so the tool still works */ }
  }

  // ---- build the prompt ----
  const system =
    'You are "Hary", a helpful data assistant embedded in the Vision Infra Report Analyzer. ' +
    'Answer the user\'s question using ONLY the JSON report data provided. ' +
    'Rules: (1) For report-wide totals, trust the values in "kpis" — they are pre-calculated and exact. ' +
    '(2) The "rows" array may be only a sample of the full dataset (see "note"); never state a grand total from the sample. ' +
    '(3) If the answer is not present in the data, say so plainly instead of guessing. ' +
    '(4) Be concise and business-friendly. Use short bullet points (start lines with "• ") and **bold** for key numbers when helpful. ' +
    '(5) Currency is Indian Rupees; "Cr" means crore. Do not invent columns or figures.';

  const dataText = summary ? JSON.stringify(summary).slice(0, 28000) : '(no report is currently open)';

  try {
    const url = 'https://generativelanguage.googleapis.com/v1beta/models/' + GEMINI_MODEL + ':generateContent?key=' + encodeURIComponent(KEY);
    const gr = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: system }] },
        contents: [{ role: 'user', parts: [{ text: 'REPORT DATA (JSON):\n' + dataText + '\n\nQUESTION: ' + question }] }],
        generationConfig: { temperature: 0.2, maxOutputTokens: 800 }
      })
    });

    if (!gr.ok) {
      const errTxt = await gr.text();
      const msg = gr.status === 429
        ? 'AI is busy right now (free-tier rate limit). Please wait a few seconds and try again.'
        : 'AI service error (' + gr.status + ').';
      res.status(200).json({ ok: false, error: msg, detail: errTxt.slice(0, 300) });
      return;
    }

    const data = await gr.json();
    const answer =
      (data && data.candidates && data.candidates[0] && data.candidates[0].content &&
        data.candidates[0].content.parts && data.candidates[0].content.parts[0] &&
        data.candidates[0].content.parts[0].text) || '';

    if (!answer) { res.status(200).json({ ok: false, error: 'AI returned an empty answer. Try rephrasing.' }); return; }
    res.status(200).json({ ok: true, answer: answer.trim() });
  } catch (e) {
    res.status(200).json({ ok: false, error: 'Could not reach the AI service. Check the server key and try again.' });
  }
};

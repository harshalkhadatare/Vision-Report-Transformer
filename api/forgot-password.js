// ============================================================================
//  Forgot password  —  OTP delivery  (Vercel serverless function)
//
//  WHY THIS EXISTS AS ITS OWN FUNCTION
//  The transactional mail_outbox is drained by pg_cron once a minute and sends
//  ONE message per tick, so a queued OTP could sit for a minute or more behind
//  report alerts. A reset code has to arrive now, so this endpoint talks to SMTP
//  directly and never touches the queue. Scheduled reports and every other
//  transactional email keep using the outbox exactly as before — nothing in that
//  path is changed.
//
//  SECURITY
//    * The clear-text code exists only inside this function, between the RPC
//      response and nodemailer. It is never returned to the browser and never
//      logged (only a masked address ever appears in a log line).
//    * otp_issue_svc requires MAIL_SECRET and is not granted to anon, so the
//      browser cannot mint or read a code by calling Supabase directly.
//    * The reply is deliberately identical whether or not the address exists.
//
//  ENVIRONMENT (same variables the report mailer already uses)
//    SUPABASE_URL, SUPABASE_SERVICE_KEY, MAIL_SECRET, PORTAL_URL,
//    GMAIL_USER + GMAIL_APP_PASSWORD  (or RESEND_API_KEY as fallback), MAIL_FROM
// ============================================================================

const TPL = require('./_email-templates.js');

let nodemailer = null;
try { nodemailer = require('nodemailer'); } catch (e) { /* falls back to Resend */ }

// Reused across warm invocations so we do not re-open SMTP for every request.
let _tx = null;
function gmailTransport() {
  const { GMAIL_USER, GMAIL_APP_PASSWORD } = process.env;
  if (!GMAIL_USER || !GMAIL_APP_PASSWORD || !nodemailer) return null;
  if (!_tx) {
    _tx = nodemailer.createTransport({
      host: 'smtp.gmail.com',
      port: 465,
      secure: true,
      auth: { user: GMAIL_USER, pass: String(GMAIL_APP_PASSWORD).replace(/\s+/g, '') },
      pool: true, maxConnections: 1, maxMessages: 50,
      // tighter than the report mailer: an OTP must fail fast rather than hang
      connectionTimeout: 10000, greetingTimeout: 7000, socketTimeout: 15000
    });
  }
  return _tx;
}

async function sendOne({ to, subject, html, from }) {
  const tx = gmailTransport();
  if (tx) {
    try { await tx.sendMail({ from, to, subject, html }); return { ok: true }; }
    catch (e) { return { ok: false, error: 'SMTP: ' + String((e && (e.response || e.message)) || e).slice(0, 200) }; }
  }
  const key = process.env.RESEND_API_KEY;
  if (!key) return { ok: false, error: 'No mail transport configured.' };
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from, to: [to], subject, html })
  });
  if (r.ok) return { ok: true };
  return { ok: false, error: (await r.text()).slice(0, 200) };
}

// never write a full address into the logs
const mask = e => String(e || '').replace(/^(.).*(@.*)$/, (m, a, b) => a + '***' + b);

module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method === 'OPTIONS') { res.status(204).end(); return; }
  if (req.method !== 'POST') { res.status(405).json({ ok: false, error: 'POST only.' }); return; }

  const { SUPABASE_URL, SUPABASE_SERVICE_KEY, MAIL_SECRET, PORTAL_URL, MAIL_FROM } = process.env;
  const missing = ['SUPABASE_URL', 'SUPABASE_SERVICE_KEY', 'MAIL_SECRET'].filter(k => !process.env[k]);
  const noTransport = !(process.env.GMAIL_USER && process.env.GMAIL_APP_PASSWORD) && !process.env.RESEND_API_KEY;
  if (missing.length || noTransport) {
    const why = missing.length ? ('missing ' + missing.join(', '))
      : 'no mail transport (set GMAIL_USER + GMAIL_APP_PASSWORD, or RESEND_API_KEY)';
    console.error('OTP: not configured -', why);
    res.status(200).json({
      ok: false, code: 'OTP_NOT_CONFIGURED',
      error: 'The reset service is not configured on the server (' + why + '). Please contact IT Support.'
    });
    return;
  }

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { body = {}; } }
  const email = String((body && body.email) || '').trim();

  // Always answer the same way, whether or not the address is on file.
  const GENERIC = { ok: true, message: 'If that email is registered, a verification code has been sent.' };
  if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { res.status(200).json(GENERIC); return; }

  try {
    const r = await fetch(SUPABASE_URL.replace(/\/$/, '') + '/rest/v1/rpc/otp_issue_svc', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: SUPABASE_SERVICE_KEY,
        Authorization: 'Bearer ' + SUPABASE_SERVICE_KEY
      },
      body: JSON.stringify({ p_secret: MAIL_SECRET, p_email: email })
    });
    const raw = await r.text();
    let out = null; try { out = JSON.parse(raw); } catch (e) { out = null; }

    // ---- Infrastructure problems are reported, NOT hidden ----------------
    // Only "does this account exist" has to stay generic. A missing RPC, a bad
    // key or a dead SMTP connection are setup faults: masking them as success
    // is what makes "the mail never arrives" impossible to diagnose.
    if (!r.ok || !out) {
      const detail = (out && (out.message || out.hint)) || raw.slice(0, 300);
      console.error('OTP: otp_issue_svc HTTP', r.status, detail);
      const missingFn = r.status === 404 || /PGRST202|could not find the function|does not exist/i.test(detail || '');
      res.status(200).json({
        ok: false,
        code: missingFn ? 'OTP_RPC_MISSING' : 'OTP_RPC_ERROR',
        error: missingFn
          ? 'Password reset is not set up on the database yet. Please ask IT to re-run supabase_setup.sql.'
          : 'The reset service could not reach the database. Please contact IT Support.'
      });
      return;
    }
    if (out.ok === false) {
      console.error('OTP: otp_issue_svc refused -', out.error || '(no reason)');
      res.status(200).json({
        ok: false, code: 'OTP_NOT_AUTHORISED',
        error: 'The reset service is not authorised (mail secret mismatch). Please contact IT Support.'
      });
      return;
    }

    // Genuinely unknown / unapproved address, or throttled: stay generic.
    if (out.send !== true) { res.status(200).json(GENERIC); return; }

    const portal = PORTAL_URL || 'https://vision-report-transformer.vercel.app';
    const built = TPL.passwordOtp({
      name: out.name, code: out.code, minutes: out.minutes || 15, user_id: out.user_id,
      portalUrl: portal, logoUrl: portal.replace(/\/$/, '') + '/images/logo.png',
      version: process.env.APP_VERSION || 'v5.1'
    });
    const hasGmail = !!(process.env.GMAIL_USER && process.env.GMAIL_APP_PASSWORD && nodemailer);
    const from = hasGmail
      ? (MAIL_FROM || ('VIESL Reports <' + process.env.GMAIL_USER + '>'))
      : (MAIL_FROM || 'VIESL Reports <onboarding@resend.dev>');

    const sent = await sendOne({ to: out.email, from, subject: built.subject, html: built.html });
    try { if (_tx) _tx.close(); } catch (e) { }   // release the pool before the lambda freezes

    if (!sent.ok) {
      console.error('OTP send failed for', mask(out.email), '-', sent.error);   // never logs the code
      // The address is already known-good at this point, so naming the transport
      // fault does not leak anything and it is the only way to debug delivery.
      res.status(200).json({
        ok: false, code: 'OTP_SMTP_FAILED',
        error: 'The code could not be emailed: ' + String(sent.error || 'mail transport error').slice(0, 160)
      });
      return;
    }
    res.status(200).json(GENERIC);
  } catch (e) {
    console.error('forgot-password error:', String((e && e.message) || e));
    res.status(200).json({ ok: false, error: 'Something went wrong. Please try again.' });
  }
};

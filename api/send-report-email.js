// ============================================================================
//  Scheduled report notification  —  Vercel serverless function
//
//  Called by Supabase pg_cron (or manually from the admin panel's "Send test").
//  Builds a branded HTML email and sends it through Resend.
//
//  TWO SEND MODES — Gmail SMTP is preferred, Resend is the fallback.
//
//  A) GMAIL SMTP (recommended: works today, no DNS verification needed).
//     Sends through your real Google Workspace mailbox, so mail genuinely comes
//     from itsupport@visioninfraindia.com and can go to ANYONE.
//        GMAIL_USER            itsupport@visioninfraindia.com
//        GMAIL_APP_PASSWORD    16-char App Password (NOT your normal password)
//     Create one at https://myaccount.google.com/apppasswords
//     Workspace limit is ~500 external recipients/day — ample here.
//
//  B) RESEND (fallback, used only when the Gmail vars are absent).
//     Until visioninfraindia.com is verified it can ONLY deliver to your own
//     Resend account address; anyone else returns 403 validation_error.
//
//  REQUIRED environment variables (Vercel > Settings > Environment Variables):
//     RESEND_API_KEY        from resend.com  (only needed for mode B)
//     SUPABASE_URL          https://xxxx.supabase.co
//     SUPABASE_SERVICE_KEY  service_role key (NEVER exposed to the browser)
//     MAIL_SECRET           same random string used in app.mail_secret
//     PORTAL_URL            https://your-app.vercel.app
//     MAIL_FROM             optional. Defaults to onboarding@resend.dev until
//                           visioninfraindia.com is verified, then set it to
//                           "VIESL Reports <reports@visioninfraindia.com>"
//
//  No npm packages needed — uses built-in fetch (Node 18+ on Vercel).
// ============================================================================

const TPL = require('./_email-templates.js');

let nodemailer = null;
try { nodemailer = require('nodemailer'); } catch (e) { /* falls back to Resend */ }

const REPORT_NAMES = {
  rental: 'P&M Rental Report',
  milling: 'Milling Machine Report',
  stock: 'Stock Report',
  pogin: 'PO-GIN-BILL-PAYMENT',
  ageing: 'Ageing Report Analysis',
  sales: 'Sales Dashboard',
  bin: 'Bin / Equipment Values',
  crusher: 'Crusher Report',
  saleorder: 'Sales Order Status',
  pmmonthly: 'P&M Monthly Report'
};

// Administrator contacts shown at the bottom of every alert.
const CONTACTS = [
  { name: 'Mr. Sandeep Patil',     role: 'Manager \u00b7 P&M / Audit',  email: 'pnm_audit@visioninfraindia.com',  phone: '+91 89566 67459' },
  { name: 'Mr. Harshal Khadatare', role: 'Data Engineer \u00b7 IT',     email: 'itsupport@visioninfraindia.com',  phone: '+91 90757 68742' }
];

// "03 Aug 2026" in IST
function todayIST() {
  return new Date().toLocaleDateString('en-GB', {
    timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric'
  });
}

// Built at SEND time so the date is always current.
//   report_date -> "P&M Rental Report - 03 Aug 2026"  (or "2 Reports - ..." when several)
//   all_summary -> "Daily Reports Summary - 03 Aug 2026"
//   custom      -> exactly what the admin typed
function buildSubject(sch, reportTypes) {
  const d = todayIST();
  const mode = sch.subject_mode || 'custom';
  const names = (reportTypes || []).map(r => REPORT_NAMES[r] || r);
  if (mode === 'all_summary') return 'Daily Reports Summary - ' + d;
  if (mode === 'report_date') {
    if (names.length === 1) return names[0] + ' - ' + d;
    if (names.length > 1)   return names.length + ' Reports - ' + d;
    return 'Report Update - ' + d;
  }
  return (sch.title && sch.title.trim())
    ? sch.title.trim()
    : 'Report update \u2014 VIESL Report Analyzer';
}

function fmtSize(b) {
  const n = Number(b) || 0;
  if (!n) return '';
  if (n < 1024) return n + ' B';
  if (n < 1048576) return (n / 1024).toFixed(0) + ' KB';
  return (n / 1048576).toFixed(1) + ' MB';
}

const esc = t => String(t == null ? '' : t)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

// "31 Jul 2026, 09:15" in IST
function fmtIST(v) {
  if (!v) return '\u2014';
  const d = new Date(v);
  if (isNaN(d)) return String(v);
  return d.toLocaleString('en-GB', {
    timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit', hour12: false
  }).replace(',', ',');
}

// ---- KPI grid: 3 per row, table-based so Outlook renders it ----
function kpiGrid(kpis, F) {
  if (!kpis || !kpis.length) return '';
  const cells = kpis.slice(0, 9);
  let rows = '';
  for (let i = 0; i < cells.length; i += 3) {
    const grp = cells.slice(i, i + 3);
    rows += '<tr>' + grp.map(k => `
      <td width="33%" valign="top" style="padding:4px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
               style="background:#ffffff;border:1px solid #e3eaf2;border-radius:9px;">
          <tr><td style="padding:11px 12px;">
            <div style="font:600 9.5px/1.2 ${F};color:#8496a9;letter-spacing:.06em;
                        text-transform:uppercase;">${esc(k.label)}</div>
            <div style="font:700 17px/1.25 ${F};color:#0e2a43;padding-top:4px;">${esc(k.value)}</div>
            ${k.sub ? `<div style="font:400 10px/1.35 ${F};color:#8496a9;padding-top:2px;">${esc(k.sub)}</div>` : ''}
          </td></tr>
        </table>
      </td>`).join('')
      + (grp.length < 3 ? '<td width="33%">&nbsp;</td>'.repeat(3 - grp.length) : '')
      + '</tr>';
  }
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0"
                 style="margin:0 -4px 6px;">${rows}</table>`;
}

// ---- one chart as a labelled bar list (no images: bars are coloured table cells) ----
const BAR_COLOURS = ['#2f6db0', '#1d9e75', '#e08a1e', '#7c5cbf', '#0891b2', '#d8504c', '#0a66c2', '#b45309'];
function chartBlock(ch, idx, F) {
  const ds = (ch.datasets || [])[0];
  if (!ds || !ch.labels || !ch.labels.length) return '';
  const pairs = ch.labels.map((l, i) => ({ l, v: Number(ds.data[i]) || 0 }))
    .sort((a, b) => b.v - a.v).slice(0, 6);
  const max = Math.max.apply(null, pairs.map(p => Math.abs(p.v)).concat([1]));
  const col = BAR_COLOURS[idx % BAR_COLOURS.length];
  const fmtV = v => Number(v).toLocaleString('en-IN', { maximumFractionDigits: 2 });

  const bars = pairs.map(p => {
    const pct = Math.max(2, Math.round((Math.abs(p.v) / max) * 100));
    return `
    <tr>
      <td width="42%" style="padding:5px 8px 5px 0;font:400 11.5px/1.35 ${F};color:#44586e;
          overflow:hidden;white-space:nowrap;">${esc(p.l)}</td>
      <td width="36%" style="padding:5px 0;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
               style="background:#eef2f7;border-radius:4px;">
          <tr><td width="${pct}%" style="background:${col};height:9px;border-radius:4px;
              font-size:0;line-height:0;">&nbsp;</td>
              <td style="font-size:0;line-height:0;">&nbsp;</td></tr>
        </table>
      </td>
      <td width="22%" align="right" style="padding:5px 0 5px 8px;
          font:600 11.5px/1.35 ${F};color:#12314f;white-space:nowrap;">${fmtV(p.v)}</td>
    </tr>`;
  }).join('');

  return `
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
         style="margin-bottom:12px;border:1px solid #e3eaf2;border-radius:10px;background:#ffffff;">
    <tr><td style="padding:13px 15px 4px;">
      <div style="font:600 12.5px/1.3 ${F};color:#12314f;">${esc(ch.title)}</div>
      ${ch.sub ? `<div style="font:400 10.5px/1.4 ${F};color:#8496a9;padding-top:2px;">${esc(ch.sub)}</div>` : ''}
    </td></tr>
    <tr><td style="padding:6px 15px 13px;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0">${bars}</table>
      ${ch.labels.length > 6 ? `<div style="font:400 10px/1.4 ${F};color:#a8b6c4;padding-top:7px;">
        Top 6 of ${ch.labels.length} &middot; full breakdown in the portal</div>` : ''}
    </td></tr>
  </table>`;
}

function buildHtml({ recipientName, title, description, reports, portalUrl, shareUrl }) {
  const logo = portalUrl.replace(/\/$/, '') + '/images/logo.png';
  const F = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif";

  // Each selected report gets its own section: header, KPIs, then its charts,
  // in the order the schedule lists them.
  const sections = (reports || []).map((r, ri) => {
    const name = esc(REPORT_NAMES[r.report_type] || r.report_type);
    const kpis = kpiGrid(r.kpis || [], F);
    const charts = (r.charts || []).map((c, i) => chartBlock(c, i, F)).join('');
    const stale = (!r.kpis || !r.kpis.length) && (!r.charts || !r.charts.length);
    return `
    <tr><td style="padding:0 28px 22px;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
             style="border:1px solid #dde6f0;border-radius:12px;background:#f8fafc;">
        <tr><td style="padding:15px 16px 12px;border-bottom:1px solid #e3eaf2;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
            <tr>
              <td style="font:700 15px/1.3 ${F};color:#0e2a43;">
                <span style="display:inline-block;background:#2f6db0;color:#ffffff;border-radius:4px;
                    font:700 10px/1 ${F};padding:4px 7px;margin-right:8px;">${ri + 1}</span>${name}
              </td>
              <td align="right" style="font:400 10.5px/1.4 ${F};color:#8496a9;white-space:nowrap;">
                ${r.uploaded_at ? 'Updated ' + esc(fmtIST(r.uploaded_at)) : 'No upload yet'}
              </td>
            </tr>
            ${r.file_name ? `<tr><td colspan="2" style="font:400 11px/1.5 ${F};color:#8496a9;padding-top:3px;">
              ${esc(r.file_name)}${r.row_count ? ' &middot; ' + Number(r.row_count).toLocaleString('en-IN') + ' records' : ''}
              ${r.file_size ? ' &middot; ' + fmtSize(r.file_size) : ''}
              ${r.uploaded_by ? ' &middot; by ' + esc(r.uploaded_by) : ''}</td></tr>` : ''}
          </table>
        </td></tr>
        <tr><td style="padding:14px 16px 16px;">
          ${stale
            ? `<div style="font:400 12px/1.6 ${F};color:#8496a9;text-align:center;padding:10px;">
                 Open this report in the portal once to include its dashboard figures here.</div>`
            : kpis + charts}
        </td></tr>
      </table>
    </td></tr>`;
  }).join('');

  const rowsUnused = (reports || []).map((r, i) => `
    <tr>
      <td style="padding:0 0 10px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
               style="border:1px solid #e3eaf2;border-radius:10px;background:#ffffff;">
          <tr>
            <td width="4" style="background:#2f6db0;border-radius:10px 0 0 10px;font-size:0;line-height:0;">&nbsp;</td>
            <td style="padding:14px 16px;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                <tr>
                  <td style="font:600 14.5px/1.35 ${F};color:#12314f;padding-bottom:4px;">
                    ${esc(REPORT_NAMES[r.report_type] || r.report_type)}
                  </td>
                  <td align="right" style="font:400 11px/1.3 ${F};color:#8496a9;padding-bottom:4px;white-space:nowrap;">
                    UPDATED
                  </td>
                </tr>
                <tr>
                  <td style="font:400 12px/1.5 ${F};color:#63788f;">
                    ${esc(r.file_name || '')}${r.row_count ? ' &nbsp;&middot;&nbsp; ' + Number(r.row_count).toLocaleString('en-IN') + ' rows' : ''}
                  </td>
                  <td align="right" style="font:600 12.5px/1.5 ${F};color:#12314f;white-space:nowrap;">
                    ${esc(fmtIST(r.uploaded_at))}
                  </td>
                </tr>
                ${r.uploaded_by ? `<tr>
                  <td colspan="2" align="right" style="font:400 11px/1.5 ${F};color:#8496a9;">
                    uploaded by ${esc(r.uploaded_by)}
                  </td></tr>` : ''}
              </table>
            </td>
          </tr>
        </table>
      </td>
    </tr>`).join('');

  const noReports = `
    <tr><td style="padding:16px;border:1px dashed #d6e0ec;border-radius:10px;
        font:400 13px/1.5 ${F};color:#8496a9;text-align:center;">
      No uploads found yet for the selected reports.
    </td></tr>`;

  return `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light only"><title>${esc(title)}</title></head>
<body style="margin:0;padding:0;background:#eef2f7;-webkit-font-smoothing:antialiased;">
  <div style="display:none;max-height:0;overflow:hidden;opacity:0;">
    ${esc(title)} &mdash; ${(reports || []).length} report(s) updated in the VIESL Report Analyzer.
  </div>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef2f7;padding:28px 12px;">
    <tr><td align="center">
      <table role="presentation" width="620" cellpadding="0" cellspacing="0"
             style="max-width:620px;width:100%;background:#ffffff;border-radius:16px;overflow:hidden;
                    box-shadow:0 1px 3px rgba(16,40,70,.07),0 14px 38px rgba(16,40,70,.11);">

        <!-- brand bar -->
        <tr><td style="background:#0e2a43;background-image:linear-gradient(135deg,#16456c 0%,#0e2a43 100%);padding:22px 28px;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
            <tr>
              <td width="86" valign="middle" style="padding-right:16px;">
                <table role="presentation" cellpadding="0" cellspacing="0"
                       style="background:#ffffff;border-radius:13px;">
                  <tr><td align="center" valign="middle" style="width:86px;height:74px;padding:9px 10px;">
                    <img src="${esc(logo)}" alt="Vision Infra Equipment Solutions Ltd" width="70"
                         style="display:block;width:70px;max-width:70px;height:auto;border:0;">
                  </td></tr>
                </table>
              </td>
              <td valign="middle">
                <div style="font:700 16.5px/1.3 ${F};color:#ffffff;letter-spacing:-.2px;">
                  Vision Infra Equipment Solutions Ltd
                </div>
                <div style="font:400 12px/1.45 ${F};color:#9fc0dd;margin-top:3px;letter-spacing:.03em;">
                  REPORT ANALYZER &nbsp;&middot;&nbsp; AUTOMATED NOTIFICATION
                </div>
              </td>
            </tr>
          </table>
        </td></tr>

        <!-- accent rule -->
        <tr><td style="height:3px;font-size:0;line-height:0;
            background:linear-gradient(90deg,#2f6db0 0%,#22b573 55%,#f0a500 100%);">&nbsp;</td></tr>

        <!-- greeting + title -->
        <tr><td style="padding:30px 28px 0;">
          <div style="font:400 14px/1.5 ${F};color:#63788f;">Hi ${esc(recipientName || 'there')},</div>
          <div style="font:700 21px/1.35 ${F};color:#0e2a43;margin:10px 0 0;letter-spacing:-.3px;">
            ${esc(title)}
          </div>
          ${description ? `<div style="font:400 14px/1.65 ${F};color:#44586e;margin-top:10px;">
            ${esc(description).replace(/\n/g, '<br>')}
          </div>` : ''}
        </td></tr>

        <!-- reports: one section each, dashboard figures inline -->
        <tr><td style="padding:24px 28px 14px;">
          <div style="font:700 10.5px/1 ${F};color:#8496a9;letter-spacing:.11em;
                      text-transform:uppercase;">
            Dashboard summary &middot; ${(reports || []).length} report${(reports || []).length === 1 ? '' : 's'}
          </div>
        </td></tr>
        ${sections || `<tr><td style="padding:0 28px 20px;">
          <div style="padding:16px;border:1px dashed #d6e0ec;border-radius:10px;
              font:400 13px/1.5 ${F};color:#8496a9;text-align:center;">
            No uploads found yet for the selected reports.
          </div></td></tr>`}

        <!-- CTA -->
        <tr><td align="center" style="padding:14px 28px 4px;">
          <table role="presentation" cellpadding="0" cellspacing="0">
            <tr><td align="center" style="background:#12885a;border-radius:10px;">
              <a href="${esc(shareUrl || portalUrl)}"
                 style="display:inline-block;padding:15px 34px;font:700 14.5px/1 ${F};
                        color:#ffffff;text-decoration:none;letter-spacing:.01em;">
                ${shareUrl ? 'View Report &nbsp;&mdash;&nbsp; no login needed' : 'Open Report Analyzer'} &nbsp;&rarr;
              </a>
            </td></tr>
          </table>
          <div style="font:400 11.5px/1.55 ${F};color:#8496a9;margin-top:12px;">
            ${shareUrl
              ? 'Opens instantly on any device. Filter and download Excel, PDF or CSV \u2014 no password required.<br>'
                + '<span style="color:#a8b6c4;">This link is personal to you and expires in 7 days.</span>'
              : 'Sign in with your usual credentials to view, filter and export the full report.'}
          </div>
        </td></tr>

        ${TPL.contactCard()}
        ${TPL.footer(process.env.APP_VERSION || 'v5.1')}
        <!-- (legacy blocks below are unused, kept out of the render) -->
        <tr style="display:none"><td style="padding:0;">
          <div style="font:700 10.5px/1 ${F};color:#8496a9;letter-spacing:.11em;
                      text-transform:uppercase;padding-bottom:11px;">Contact us</div>
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
                 style="border:1px solid #e3eaf2;border-radius:12px;background:#f8fafc;">
            <tr>
              ${CONTACTS.map((c, i) => `
              <td width="50%" valign="top" style="padding:15px 16px;${i === 0 ? 'border-right:1px solid #e3eaf2;' : ''}">
                <div style="font:600 13.5px/1.35 ${F};color:#12314f;">${esc(c.name)}</div>
                <div style="font:400 11.5px/1.45 ${F};color:#8496a9;padding:2px 0 8px;">${esc(c.role)}</div>
                <div style="font:400 12px/1.7 ${F};color:#44586e;">
                  <a href="mailto:${esc(c.email)}" style="color:#2f6db0;text-decoration:none;">${esc(c.email)}</a><br>
                  <a href="tel:${esc(c.phone.replace(/\s/g, ''))}" style="color:#44586e;text-decoration:none;">${esc(c.phone)}</a>
                </div>
              </td>`).join('')}
            </tr>
          </table>
        </td></tr>

        <!-- footer -->
        <tr><td style="padding:22px 28px 26px;">
          <div style="border-top:1px solid #e6ecf3;padding-top:16px;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
              <tr><td style="font:400 11.5px/1.65 ${F};color:#8496a9;">
                Sent automatically on ${esc(fmtIST(new Date()))} IST.<br>
                You are receiving this because an administrator added you to this report schedule.
              </td></tr>
              <tr><td style="padding-top:12px;font:400 11px/1.6 ${F};color:#a8b6c4;">
                Vision Infra Equipment Solutions Ltd &nbsp;&middot;&nbsp; 4th floor, International Business Bay,<br>
                Gurunanak Nagar, Pune 411042, Maharashtra, India
              </td></tr>
            </table>
          </div>
        </td></tr>

      </table>
    </td></tr>
  </table>
</body></html>`;
}

// Reused across warm invocations so we are not re-opening SMTP on every email.
let _tx = null;
function gmailTransport() {
  const { GMAIL_USER, GMAIL_APP_PASSWORD } = process.env;
  if (!GMAIL_USER || !GMAIL_APP_PASSWORD || !nodemailer) return null;
  if (!_tx) {
    _tx = nodemailer.createTransport({
      host: 'smtp.gmail.com',
      port: 465,
      secure: true,                               // implicit TLS; avoids STARTTLS races
      auth: { user: GMAIL_USER, pass: String(GMAIL_APP_PASSWORD).replace(/\s+/g, '') },
      pool: true, maxConnections: 1, maxMessages: 50,
      connectionTimeout: 15000, greetingTimeout: 10000, socketTimeout: 20000
    });
  }
  return _tx;
}

// Returns { ok, error } for one recipient, via whichever transport is configured.
async function sendOne({ to, subject, html, from }) {
  const tx = gmailTransport();
  if (tx) {
    try {
      await tx.sendMail({ from, to, subject, html });
      return { ok: true };
    } catch (e) {
      // surface Gmail's own wording (bad App Password, quota, blocked sign-in…)
      return { ok: false, error: 'SMTP: ' + String(e && (e.response || e.message) || e).slice(0, 200) };
    }
  }
  const key = process.env.RESEND_API_KEY;
  if (!key) return { ok: false, error: 'No mail transport configured (set GMAIL_USER + GMAIL_APP_PASSWORD, or RESEND_API_KEY).' };
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from, to: [to], subject, html })
  });
  if (r.ok) return { ok: true };
  return { ok: false, error: (await r.text()).slice(0, 200) };
}

module.exports = async (req, res) => {
  if (req.method === 'OPTIONS') { res.status(204).end(); return; }
  if (req.method !== 'POST') { res.status(405).json({ ok: false, error: 'Method not allowed.' }); return; }

  const {
    RESEND_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_KEY,
    MAIL_SECRET, PORTAL_URL, MAIL_FROM
  } = process.env;

  const missing = ['SUPABASE_URL', 'SUPABASE_SERVICE_KEY'].filter(k => !process.env[k]);
  const hasGmail  = !!(process.env.GMAIL_USER && process.env.GMAIL_APP_PASSWORD && nodemailer);
  const hasResend = !!process.env.RESEND_API_KEY;
  if (!hasGmail && !hasResend) missing.push('GMAIL_USER + GMAIL_APP_PASSWORD (or RESEND_API_KEY)');
  if (missing.length) {
    res.status(500).json({ ok: false, error: 'Server is missing: ' + missing.join(', ') });
    return;
  }

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { body = {}; } }
  const scheduleId = body && body.schedule_id;
  const outboxId   = body && body.outbox_id;
  const testTo = body && body.test_to;            // "Send test" from the admin panel
  if (!scheduleId && !outboxId) { res.status(400).json({ ok: false, error: 'No schedule_id or outbox_id supplied.' }); return; }

  // shared-secret check (skipped for admin "send test", which carries its own token check)
  if (MAIL_SECRET && !testTo && req.headers['x-mail-secret'] !== MAIL_SECRET) {
    res.status(401).json({ ok: false, error: 'Bad or missing secret.' });
    return;
  }

  // NOTE: some RPCs (email_mark_sent) are `returns void` and reply 204 with an
  // EMPTY body. Calling .json() on that throws "Unexpected end of JSON input",
  // which used to be caught below and logged as a phantom 'failed' row right
  // after a successful send. Read text first, parse only if there is something.
  const sb = async (fn, args) => {
    const r = await fetch(SUPABASE_URL.replace(/\/$/, '') + '/rest/v1/rpc/' + fn, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: SUPABASE_SERVICE_KEY,
        Authorization: 'Bearer ' + SUPABASE_SERVICE_KEY
      },
      body: JSON.stringify(args)
    });
    const raw = await r.text();
    if (!raw) return null;
    try { return JSON.parse(raw); } catch (e) { return null; }
  };

  const portalDefault = PORTAL_URL || 'https://vision-report-transformer.vercel.app';
  const logoUrl = portalDefault.replace(/\/$/, '') + '/images/logo.png';
  const APP_VERSION = process.env.APP_VERSION || 'v5.1';

  // ---------- transactional mail (approval, reset, lockout, ...) ----------
  if (outboxId) {
    try {
      const ob = await sb('outbox_payload_svc', { p_id: outboxId });
      if (!ob || ob.ok !== true) {
        res.status(200).json({ ok: false, error: (ob && ob.error) || 'Outbox item not found.' });
        return;
      }
      const d = Object.assign({}, ob.payload || {}, {
        portalUrl: portalDefault, logoUrl, version: APP_VERSION
      });
      const maker = TPL[ob.template];
      if (typeof maker !== 'function') {
        await sb('outbox_mark', { p_id: outboxId, p_status: 'failed', p_detail: 'Unknown template: ' + ob.template });
        res.status(200).json({ ok: false, error: 'Unknown template: ' + ob.template });
        return;
      }
      const built = maker(d);
      const from = hasGmail
        ? (MAIL_FROM || ('VIESL Reports <' + process.env.GMAIL_USER + '>'))
        : (MAIL_FROM || 'VIESL Reports <onboarding@resend.dev>');
      const r = await sendOne({ to: ob.to_email, from, subject: built.subject, html: built.html });
      try { if (_tx) _tx.close(); } catch (e) { }
      await sb('outbox_mark', {
        p_id: outboxId,
        p_status: r.ok ? 'sent' : 'failed',
        p_detail: '[' + (hasGmail ? 'gmail' : 'resend') + '] ' + (r.ok ? 'sent to ' + ob.to_email : r.error)
      });
      res.status(200).json({ ok: r.ok, template: ob.template, to: ob.to_email, error: r.error });
      return;
    } catch (e) {
      try { await sb('outbox_mark', { p_id: outboxId, p_status: 'failed', p_detail: String(e.message || e) }); } catch (_) { }
      res.status(200).json({ ok: false, error: String(e.message || e) });
      return;
    }
  }

  let logged = false;
  try {
    const payload = await sb('email_payload_svc', { p_id: scheduleId });
    if (!payload || payload.ok !== true) {
      res.status(200).json({ ok: false, error: (payload && payload.error) || 'Could not load schedule.' });
      return;
    }

    const sch = payload.schedule || {};
    const reports = payload.reports || [];
    let recipients = payload.recipients || [];
    if (testTo) recipients = [{ name: 'Test recipient', user_id: 'test', email: testTo }];

    if (!recipients.length) {
      try { await sb('email_mark_sent', { p_id: scheduleId, p_status: 'skipped', p_detail: 'No recipients have an email address on file.' }); } catch (_) { }
      logged = true;
      res.status(200).json({ ok: false, error: 'No recipients have an email address on file.' });
      return;
    }

    // Gmail must send as the authenticated mailbox, otherwise Google rewrites or rejects it.
    const from = hasGmail
      ? (MAIL_FROM || ('VIESL Reports <' + process.env.GMAIL_USER + '>'))
      : (MAIL_FROM || 'VIESL Reports <onboarding@resend.dev>');
    const portal = PORTAL_URL || 'https://vision-report-transformer.vercel.app';

    let sent = 0; const failures = [];
    // "management" schedules: mint a personal, expiring, revocable link per recipient
    const wantShare = !!sch.share_access;
    for (const p of recipients) {
      let shareUrl = null;
      if (wantShare && reports.length) {
        try {
          const tk = await sb('share_token_issue', {
            p_schedule_id: scheduleId,
            p_report_type: reports[0].report_type,   // link opens the first report
            p_recipient: p.user_id,
            p_recipient_email: p.email
          });
          if (tk && tk.ok && tk.token) {
            shareUrl = portal.replace(/\/$/, '') + '/?share=' + tk.token;
          }
        } catch (e) { /* fall back to the normal login link */ }
      }
      const html = buildHtml({
        recipientName: p.name, title: sch.title, description: sch.description,
        reports, portalUrl: portal, shareUrl
      });
      const r = await sendOne({
        to: p.email, from, html,
        subject: buildSubject(sch, sch.report_types)
      });
      if (r.ok) sent++; else failures.push(p.email + ': ' + r.error);
    }
    try { if (_tx) _tx.close(); } catch (e) { }   // release the SMTP pool before the lambda freezes

    const status = failures.length === 0 ? 'sent' : (sent > 0 ? 'partial' : 'failed');
    const detail = '[' + (hasGmail ? 'gmail' : 'resend') + (sch.share_access ? ' \u00b7 share' : '') + '] ' + sent + ' sent' + (failures.length ? ' \u00b7 ' + failures.length + ' failed \u00b7 ' + failures[0] : '');
    // logging must never turn a successful send into a 'failed' row
    if (!testTo) { try { await sb('email_mark_sent', { p_id: scheduleId, p_status: status, p_detail: detail }); } catch (_) { } }
    logged = true;

    res.status(200).json({ ok: sent > 0, sent, failed: failures.length, detail, transport: hasGmail ? 'gmail' : 'resend' });
  } catch (e) {
    // only log here if the send itself never reported a result, otherwise a
    // post-send hiccup would append a duplicate 'failed' row to a real send.
    if (!logged && !testTo) {
      try { await sb('email_mark_sent', { p_id: scheduleId, p_status: 'failed', p_detail: String(e.message || e) }); } catch (_) { }
    }
    res.status(200).json({ ok: false, error: 'Send failed: ' + (e.message || e) });
  }
};

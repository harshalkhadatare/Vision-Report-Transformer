// ============================================================================
//  Scheduled report notification  —  Vercel serverless function
//
//  Called by Supabase pg_cron (or manually from the admin panel's "Send test").
//  Builds a branded HTML email and sends it through Resend.
//
//  REQUIRED environment variables (Vercel > Settings > Environment Variables):
//     RESEND_API_KEY        from resend.com  (free tier: 100/day, 3000/month)
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

const REPORT_NAMES = {
  rental: 'P&M Rental Report',
  milling: 'Milling Machine Report',
  stock: 'Stock Report',
  pogin: 'PO-GIN-BILL-PAYMENT',
  ageing: 'Ageing Report Analysis',
  sales: 'Sales Dashboard'
};

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

function buildHtml({ recipientName, title, description, reports, portalUrl }) {
  const logo = portalUrl.replace(/\/$/, '') + '/images/logo.png';
  const F = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif";

  const rows = (reports || []).map((r, i) => `
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
              <td width="52" valign="middle" style="padding-right:14px;">
                <table role="presentation" cellpadding="0" cellspacing="0"
                       style="background:#ffffff;border-radius:11px;">
                  <tr><td align="center" valign="middle" style="width:52px;height:52px;padding:6px;">
                    <img src="${esc(logo)}" alt="VIESL" width="40"
                         style="display:block;width:40px;height:auto;border:0;">
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

        <!-- reports -->
        <tr><td style="padding:24px 28px 0;">
          <div style="font:700 10.5px/1 ${F};color:#8496a9;letter-spacing:.11em;
                      text-transform:uppercase;padding-bottom:11px;">
            Reports in this update
          </div>
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
            ${rows || noReports}
          </table>
        </td></tr>

        <!-- CTA -->
        <tr><td align="center" style="padding:14px 28px 4px;">
          <table role="presentation" cellpadding="0" cellspacing="0">
            <tr><td align="center" style="background:#12885a;border-radius:10px;">
              <a href="${esc(portalUrl)}"
                 style="display:inline-block;padding:15px 34px;font:700 14.5px/1 ${F};
                        color:#ffffff;text-decoration:none;letter-spacing:.01em;">
                Open Report Analyzer &nbsp;&rarr;
              </a>
            </td></tr>
          </table>
          <div style="font:400 11.5px/1.55 ${F};color:#8496a9;margin-top:12px;">
            Sign in with your usual credentials to view, filter and export the full report.
          </div>
        </td></tr>

        <!-- footer -->
        <tr><td style="padding:24px 28px 26px;">
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

module.exports = async (req, res) => {
  if (req.method === 'OPTIONS') { res.status(204).end(); return; }
  if (req.method !== 'POST') { res.status(405).json({ ok: false, error: 'Method not allowed.' }); return; }

  const {
    RESEND_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_KEY,
    MAIL_SECRET, PORTAL_URL, MAIL_FROM
  } = process.env;

  const missing = ['RESEND_API_KEY', 'SUPABASE_URL', 'SUPABASE_SERVICE_KEY']
    .filter(k => !process.env[k]);
  if (missing.length) {
    res.status(500).json({ ok: false, error: 'Server is missing: ' + missing.join(', ') });
    return;
  }

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { body = {}; } }
  const scheduleId = body && body.schedule_id;
  const testTo = body && body.test_to;            // "Send test" from the admin panel
  if (!scheduleId) { res.status(400).json({ ok: false, error: 'No schedule_id supplied.' }); return; }

  // shared-secret check (skipped for admin "send test", which carries its own token check)
  if (MAIL_SECRET && !testTo && req.headers['x-mail-secret'] !== MAIL_SECRET) {
    res.status(401).json({ ok: false, error: 'Bad or missing secret.' });
    return;
  }

  const sb = (fn, args) => fetch(SUPABASE_URL.replace(/\/$/, '') + '/rest/v1/rpc/' + fn, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: SUPABASE_SERVICE_KEY,
      Authorization: 'Bearer ' + SUPABASE_SERVICE_KEY
    },
    body: JSON.stringify(args)
  }).then(r => r.json());

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
      await sb('email_mark_sent', { p_id: scheduleId, p_status: 'skipped', p_detail: 'No recipients have an email address on file.' });
      res.status(200).json({ ok: false, error: 'No recipients have an email address on file.' });
      return;
    }

    const from = MAIL_FROM || 'VIESL Reports <onboarding@resend.dev>';
    const portal = PORTAL_URL || 'https://vision-report-transformer.vercel.app';

    let sent = 0; const failures = [];
    for (const p of recipients) {
      const html = buildHtml({
        recipientName: p.name, title: sch.title, description: sch.description,
        reports, portalUrl: portal
      });
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: 'Bearer ' + RESEND_API_KEY, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from, to: [p.email],
          subject: sch.title || 'Report update \u2014 VIESL Report Analyzer',
          html
        })
      });
      if (r.ok) sent++;
      else failures.push(p.email + ': ' + (await r.text()).slice(0, 160));
    }

    const status = failures.length === 0 ? 'sent' : (sent > 0 ? 'partial' : 'failed');
    const detail = sent + ' sent' + (failures.length ? ' \u00b7 ' + failures.length + ' failed \u00b7 ' + failures[0] : '');
    if (!testTo) await sb('email_mark_sent', { p_id: scheduleId, p_status: status, p_detail: detail });

    res.status(200).json({ ok: sent > 0, sent, failed: failures.length, detail });
  } catch (e) {
    try { await sb('email_mark_sent', { p_id: scheduleId, p_status: 'failed', p_detail: String(e.message || e) }); } catch (_) { }
    res.status(200).json({ ok: false, error: 'Send failed: ' + (e.message || e) });
  }
};

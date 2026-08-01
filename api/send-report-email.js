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
  const rows = (reports || []).map(r => `
    <tr>
      <td style="padding:13px 16px;border-bottom:1px solid #e6ecf3;">
        <div style="font:600 14px/1.35 Segoe UI,Arial,sans-serif;color:#12314f;">
          ${esc(REPORT_NAMES[r.report_type] || r.report_type)}
        </div>
        <div style="font:400 12px/1.5 Segoe UI,Arial,sans-serif;color:#63788f;margin-top:3px;">
          ${esc(r.file_name || '')}${r.row_count ? ' &middot; ' + Number(r.row_count).toLocaleString('en-IN') + ' rows' : ''}
        </div>
      </td>
      <td style="padding:13px 16px;border-bottom:1px solid #e6ecf3;text-align:right;white-space:nowrap;">
        <div style="font:400 11px/1.4 Segoe UI,Arial,sans-serif;color:#8496a9;">Updated</div>
        <div style="font:600 12.5px/1.4 Segoe UI,Arial,sans-serif;color:#12314f;">${esc(fmtIST(r.uploaded_at))}</div>
        ${r.uploaded_by ? `<div style="font:400 11px/1.4 Segoe UI,Arial,sans-serif;color:#8496a9;">by ${esc(r.uploaded_by)}</div>` : ''}
      </td>
    </tr>`).join('');

  const noReports = `
    <tr><td colspan="2" style="padding:16px;font:400 13px/1.5 Segoe UI,Arial,sans-serif;color:#8496a9;">
      No uploads found yet for the selected reports.
    </td></tr>`;

  return `<!doctype html>
<html><body style="margin:0;padding:0;background:#eef2f7;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef2f7;padding:26px 12px;">
    <tr><td align="center">
      <table role="presentation" width="600" cellpadding="0" cellspacing="0"
             style="max-width:600px;width:100%;background:#ffffff;border-radius:14px;overflow:hidden;
                    box-shadow:0 2px 6px rgba(16,40,70,.08),0 12px 34px rgba(16,40,70,.10);">

        <tr><td style="background:linear-gradient(135deg,#16456c,#0e2a43);padding:22px 26px;">
          <div style="font:700 17px/1.3 Segoe UI,Arial,sans-serif;color:#ffffff;">
            Vision Infra Equipment Solutions Ltd
          </div>
          <div style="font:400 12.5px/1.4 Segoe UI,Arial,sans-serif;color:#a8c4dd;margin-top:3px;">
            Report Analyzer &middot; automated notification
          </div>
        </td></tr>

        <tr><td style="padding:26px 26px 6px;">
          <div style="font:400 14px/1.5 Segoe UI,Arial,sans-serif;color:#12314f;">
            Hi ${esc(recipientName || 'there')},
          </div>
          <div style="font:700 19px/1.35 Segoe UI,Arial,sans-serif;color:#0e2a43;margin:12px 0 8px;">
            ${esc(title)}
          </div>
          ${description ? `<div style="font:400 14px/1.6 Segoe UI,Arial,sans-serif;color:#44586e;margin-bottom:6px;">
            ${esc(description).replace(/\n/g, '<br>')}
          </div>` : ''}
        </td></tr>

        <tr><td style="padding:14px 26px 4px;">
          <div style="font:700 11px/1 Segoe UI,Arial,sans-serif;color:#8496a9;letter-spacing:.08em;
                      text-transform:uppercase;margin-bottom:9px;">Reports</div>
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
                 style="border:1px solid #e6ecf3;border-radius:10px;overflow:hidden;">
            ${rows || noReports}
          </table>
        </td></tr>

        <tr><td style="padding:22px 26px 4px;" align="center">
          <a href="${esc(portalUrl)}"
             style="display:inline-block;background:#12885a;color:#ffffff;text-decoration:none;
                    font:700 14px/1 Segoe UI,Arial,sans-serif;padding:14px 30px;border-radius:9px;">
            Open Report Analyzer &rarr;
          </a>
          <div style="font:400 11.5px/1.5 Segoe UI,Arial,sans-serif;color:#8496a9;margin-top:11px;">
            Sign in with your usual credentials to view and export the full report.
          </div>
        </td></tr>

        <tr><td style="padding:20px 26px 24px;">
          <div style="border-top:1px solid #e6ecf3;padding-top:14px;
                      font:400 11.5px/1.6 Segoe UI,Arial,sans-serif;color:#8496a9;">
            Sent automatically by the VIESL Report Analyzer on ${esc(fmtIST(new Date()))} (IST).<br>
            You are receiving this because an administrator added you to this report schedule.
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

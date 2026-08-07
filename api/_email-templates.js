// ============================================================================
//  VIESL Report Analyzer — email templates
//
//  One shared shell (logo header, accent rule, contact card, footer) wraps every
//  message, so branding, spacing and typography stay identical across:
//     approved · reportUpdate · scheduled · passwordReset · accountLocked · accountCreated
//
//  All layout is table-based with inline styles: Outlook ignores <style> blocks
//  and strips flex/grid, so anything else silently falls apart there.
// ============================================================================

const F = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif";

const BRAND = {
  name: 'Vision Infra Equipment Solutions Ltd',
  short: 'VIESL',
  address: '4th floor, International Business Bay, Gurunanak Nagar, Pune 411042, Maharashtra, India',
  website: 'https://www.visioninfraindia.com',
  hours: 'Monday – Saturday, 9:30 AM – 6:30 PM IST'
};

const CONTACTS = [
  { name: 'Mr. Sandeep Patil', role: 'Manager · P&M / Audit', email: 'pnm_audit@visioninfraindia.com', phone: '+91 89566 67459' },
  { name: 'Mr. Harshal Khadatare', role: 'IT Support · Data Engineer', email: 'itsupport@visioninfraindia.com', phone: '+91 90757 68742' }
];

const esc = t => String(t == null ? '' : t)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

const nf = v => Number(v || 0).toLocaleString('en-IN', { maximumFractionDigits: 2 });

function fmtIST(v) {
  if (!v) return '\u2014';
  const d = new Date(v); if (isNaN(d)) return String(v);
  return d.toLocaleString('en-GB', {
    timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit', hour12: false
  });
}

/* ---------------------------------------------------------------- shell ---- */

function header(logoUrl, accent) {
  return `
  <tr><td style="background:#0e2a43;background-image:linear-gradient(135deg,#16456c 0%,#0e2a43 100%);padding:22px 28px;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
      <td width="86" valign="middle" style="padding-right:16px;">
        <table role="presentation" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:13px;">
          <tr><td align="center" valign="middle" style="width:86px;height:74px;padding:9px 10px;">
            <img src="${esc(logoUrl)}" alt="${esc(BRAND.name)}" width="70"
                 style="display:block;width:70px;max-width:70px;height:auto;border:0;">
          </td></tr>
        </table>
      </td>
      <td valign="middle">
        <div style="font:700 16.5px/1.3 ${F};color:#ffffff;letter-spacing:-.2px;">${esc(BRAND.name)}</div>
        <div style="font:400 12px/1.45 ${F};color:#9fc0dd;margin-top:3px;letter-spacing:.03em;">
          REPORT ANALYZER &nbsp;&middot;&nbsp; AUTOMATED NOTIFICATION
        </div>
      </td>
    </tr></table>
  </td></tr>
  <tr><td style="height:3px;font-size:0;line-height:0;background:${accent};">&nbsp;</td></tr>`;
}

function contactCard() {
  return `
  <tr><td style="padding:26px 28px 0;">
    <div style="font:700 10.5px/1 ${F};color:#8496a9;letter-spacing:.11em;text-transform:uppercase;padding-bottom:11px;">
      Need help? Contact us
    </div>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
           style="border:1px solid #e3eaf2;border-radius:12px;background:#f8fafc;">
      <tr>
        ${CONTACTS.map((c, i) => `
        <td width="50%" valign="top" style="padding:15px 16px;${i === 0 ? 'border-right:1px solid #e3eaf2;' : ''}">
          <div style="font:600 13.5px/1.35 ${F};color:#12314f;">${esc(c.name)}</div>
          <div style="font:400 11.5px/1.45 ${F};color:#8496a9;padding:2px 0 8px;">${esc(c.role)}</div>
          <div style="font:400 12px/1.75 ${F};color:#44586e;">
            <span style="color:#8496a9;">&#9993;</span>
            <a href="mailto:${esc(c.email)}" style="color:#2f6db0;text-decoration:none;">${esc(c.email)}</a><br>
            <span style="color:#8496a9;">&#9742;</span>
            <a href="tel:${esc(c.phone.replace(/\s/g, ''))}" style="color:#44586e;text-decoration:none;">${esc(c.phone)}</a>
          </div>
        </td>`).join('')}
      </tr>
      <tr><td colspan="2" style="padding:0 16px 14px;border-top:1px solid #e3eaf2;">
        <div style="font:400 11.5px/1.7 ${F};color:#63788f;padding-top:11px;">
          <span style="color:#8496a9;">&#128336;</span> ${esc(BRAND.hours)}<br>
          <span style="color:#8496a9;">&#127760;</span>
          <a href="${esc(BRAND.website)}" style="color:#2f6db0;text-decoration:none;">${esc(BRAND.website.replace(/^https?:\/\//, ''))}</a><br>
          <span style="color:#8496a9;">&#127970;</span> ${esc(BRAND.address)}
        </div>
      </td></tr>
    </table>
  </td></tr>`;
}

function footer(version) {
  return `
  <tr><td style="padding:22px 28px 26px;">
    <div style="border-top:1px solid #e6ecf3;padding-top:15px;font:400 11px/1.7 ${F};color:#a8b6c4;">
      &copy; ${new Date().getFullYear()} ${esc(BRAND.name)}. All rights reserved.<br>
      Report Analyzer ${esc(version || '')} &nbsp;&middot;&nbsp; generated ${esc(fmtIST(new Date()))} IST<br>
      <span style="color:#b9c4d0;">This is an automated message &mdash; please do not reply to this address.</span>
    </div>
  </td></tr>`;
}

// every template goes through here
function shell({ title, preheader, logoUrl, accent, body, version, showContacts = true }) {
  return `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light only"><title>${esc(title)}</title></head>
<body style="margin:0;padding:0;background:#eef2f7;-webkit-font-smoothing:antialiased;">
  <div style="display:none;max-height:0;overflow:hidden;opacity:0;">${esc(preheader || title)}</div>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef2f7;padding:28px 12px;">
    <tr><td align="center">
      <table role="presentation" width="620" cellpadding="0" cellspacing="0"
             style="max-width:620px;width:100%;background:#ffffff;border-radius:16px;overflow:hidden;
                    box-shadow:0 1px 3px rgba(16,40,70,.07),0 14px 38px rgba(16,40,70,.11);">
        ${header(logoUrl, accent || 'linear-gradient(90deg,#2f6db0 0%,#22b573 55%,#f0a500 100%)')}
        ${body}
        ${showContacts ? contactCard() : ''}
        ${footer(version)}
      </table>
    </td></tr>
  </table>
</body></html>`;
}

/* ------------------------------------------------------- shared fragments -- */

function ctaButton(url, label, colour) {
  return `
  <tr><td align="center" style="padding:16px 28px 4px;">
    <table role="presentation" cellpadding="0" cellspacing="0">
      <tr><td align="center" style="background:${colour || '#12885a'};border-radius:10px;">
        <a href="${esc(url)}" style="display:inline-block;padding:15px 34px;font:700 14.5px/1 ${F};
           color:#ffffff;text-decoration:none;letter-spacing:.01em;">${label}</a>
      </td></tr>
    </table>
  </td></tr>`;
}

function detailRows(pairs) {
  return `
  <tr><td style="padding:20px 28px 0;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
           style="border:1px solid #e3eaf2;border-radius:11px;overflow:hidden;">
      ${pairs.filter(p => p[1]).map((p, i) => `
      <tr${i % 2 ? ' style="background:#f8fafc;"' : ''}>
        <td width="42%" style="padding:11px 15px;font:400 12px/1.4 ${F};color:#8496a9;">${esc(p[0])}</td>
        <td style="padding:11px 15px;font:600 12.5px/1.4 ${F};color:#12314f;">${esc(p[1])}</td>
      </tr>`).join('')}
    </table>
  </td></tr>`;
}

function noticeBar(text, bg, fg) {
  return `
  <tr><td style="padding:18px 28px 0;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
           style="background:${bg};border-radius:10px;">
      <tr><td style="padding:13px 16px;font:400 12.5px/1.6 ${F};color:${fg};">${text}</td></tr>
    </table>
  </td></tr>`;
}

/* ------------------------------------------------------------- templates -- */

// 1. account approved — celebratory green
function approved({ name, user_id, email, role, dept, approved_by, approved_at, portalUrl, logoUrl, version }) {
  const body = `
  <tr><td align="center" style="padding:34px 28px 0;">
    <table role="presentation" cellpadding="0" cellspacing="0">
      <tr><td align="center" style="width:74px;height:74px;background:#e6f7ef;border-radius:50%;">
        <div style="font:700 34px/74px ${F};color:#12885a;">&#10003;</div>
      </td></tr>
    </table>
    <div style="font:700 23px/1.3 ${F};color:#0e2a43;padding-top:18px;letter-spacing:-.3px;">
      Welcome to Report Analyzer
    </div>
    <div style="font:600 14px/1.5 ${F};color:#12885a;padding-top:7px;">
      Your account has been approved
    </div>
  </td></tr>
  <tr><td style="padding:18px 28px 0;">
    <div style="font:400 14px/1.65 ${F};color:#44586e;">
      Hello <b style="color:#12314f;">${esc(name)}</b>,<br><br>
      Your registration has been reviewed and approved by the administrator.
      You can now sign in and start analysing your ERP reports.
    </div>
  </td></tr>
  ${detailRows([
    ['Full name', name],
    ['Username', user_id],
    ['Official email', email],
    ['Role', role === 'admin' ? 'Administrator' : 'User'],
    ['Department', dept],
    ['Approved by', approved_by],
    ['Approved on', fmtIST(approved_at)]
  ])}
  ${ctaButton(portalUrl, 'Login to Report Analyzer &nbsp;&rarr;', '#12885a')}
  <tr><td align="center" style="padding:11px 28px 0;">
    <div style="font:400 11.5px/1.6 ${F};color:#8496a9;">
      Sign in with the User ID <b style="color:#44586e;">${esc(user_id)}</b> and the password you chose at registration.
    </div>
  </td></tr>`;
  return {
    subject: 'Your Report Analyzer account has been approved',
    html: shell({
      title: 'Account approved', preheader: 'Welcome aboard — your Report Analyzer account is ready.',
      logoUrl, version, body,
      accent: 'linear-gradient(90deg,#12885a 0%,#22b573 55%,#7fd6a8 100%)'
    })
  };
}

// 2. account created — awaiting approval
function accountCreated({ name, user_id, email, portalUrl, logoUrl, version }) {
  const body = `
  <tr><td style="padding:30px 28px 0;">
    <div style="font:700 20px/1.35 ${F};color:#0e2a43;letter-spacing:-.2px;">Registration received</div>
    <div style="font:400 14px/1.65 ${F};color:#44586e;padding-top:11px;">
      Hello <b style="color:#12314f;">${esc(name)}</b>,<br><br>
      Thanks for registering. Your request is now with the administrator for review.
      You will get another email as soon as it is approved.
    </div>
  </td></tr>
  ${detailRows([['Full name', name], ['Username', user_id], ['Official email', email]])}
  ${noticeBar('Access is granted only after an administrator approves the request. No action is needed from you in the meantime.', '#fff8e6', '#8a6200')}`;
  return {
    subject: 'Report Analyzer registration received',
    html: shell({ title: 'Registration received', preheader: 'Your request is awaiting administrator approval.',
      logoUrl, version, body, accent: 'linear-gradient(90deg,#2f6db0 0%,#5b9bf8 100%)' })
  };
}

// 3. password reset
function passwordReset({ name, user_id, reset_by, portalUrl, logoUrl, version, temp_note }) {
  const body = `
  <tr><td style="padding:30px 28px 0;">
    <div style="font:700 20px/1.35 ${F};color:#0e2a43;letter-spacing:-.2px;">Your password was reset</div>
    <div style="font:400 14px/1.65 ${F};color:#44586e;padding-top:11px;">
      Hello <b style="color:#12314f;">${esc(name)}</b>,<br><br>
      The password for your Report Analyzer account was reset${reset_by ? ' by <b>' + esc(reset_by) + '</b>' : ''}.
    </div>
  </td></tr>
  ${detailRows([['Username', user_id], ['Reset on', fmtIST(new Date())]])}
  ${temp_note ? noticeBar(esc(temp_note), '#eef4fb', '#274b73') : ''}
  ${noticeBar('If you did not expect this, contact IT Support immediately using the details below.', '#fdeceb', '#8a2019')}
  ${ctaButton(portalUrl, 'Go to Report Analyzer &nbsp;&rarr;', '#2f6db0')}`;
  return {
    subject: 'Your Report Analyzer password was reset',
    html: shell({ title: 'Password reset', preheader: 'Your account password has been changed.',
      logoUrl, version, body, accent: 'linear-gradient(90deg,#2f6db0 0%,#5b9bf8 100%)' })
  };
}

// 4. account locked
function accountLocked({ name, user_id, attempts, locked_until, portalUrl, logoUrl, version }) {
  const body = `
  <tr><td style="padding:30px 28px 0;">
    <div style="font:700 20px/1.35 ${F};color:#8a2019;letter-spacing:-.2px;">&#9888; Account temporarily locked</div>
    <div style="font:400 14px/1.65 ${F};color:#44586e;padding-top:11px;">
      Hello <b style="color:#12314f;">${esc(name)}</b>,<br><br>
      Your account was locked after repeated failed sign-in attempts. This is an automatic
      security measure and it unlocks by itself.
    </div>
  </td></tr>
  ${detailRows([['Username', user_id], ['Failed attempts', attempts != null ? String(attempts) : ''],
                ['Locked until', locked_until ? fmtIST(locked_until) : 'a short period']])}
  ${noticeBar('If this was not you, please contact IT Support straight away.', '#fdeceb', '#8a2019')}`;
  return {
    subject: 'Security alert: your Report Analyzer account was locked',
    html: shell({ title: 'Account locked', preheader: 'Your account was locked after failed sign-in attempts.',
      logoUrl, version, body, accent: 'linear-gradient(90deg,#b3261e 0%,#e08a1e 100%)' })
  };
}


// 5. password reset OTP  (sent immediately by api/forgot-password.js)
function passwordOtp({ name, code, minutes, user_id, portalUrl, logoUrl, version }) {
  const mins = minutes || 15;
  const body = `
  <tr><td style="padding:30px 28px 0;">
    <div style="font:700 20px/1.35 ${F};color:#0e2a43;letter-spacing:-.2px;">Your password reset code</div>
    <div style="font:400 14px/1.65 ${F};color:#44586e;padding-top:11px;">
      Hello <b style="color:#12314f;">${esc(name)}</b>,<br><br>
      Use the verification code below to reset your Report Analyzer password.
    </div>
  </td></tr>
  <tr><td style="padding:22px 28px 0;">
    <div style="background:#eef4fb;border:1px solid #cfe0f2;border-radius:12px;padding:18px 10px;text-align:center;">
      <div style="font:600 11px/1 ${F};letter-spacing:1.4px;text-transform:uppercase;color:#5a7a99;">Verification code</div>
      <div style="font:700 34px/1.2 ${F};color:#0e2a43;letter-spacing:9px;padding-top:9px;">${esc(code)}</div>
      <div style="font:400 12px/1.5 ${F};color:#5a7a99;padding-top:8px;">Valid for ${mins} minutes &middot; single use</div>
    </div>
  </td></tr>
  ${detailRows([['Username', user_id], ['Requested on', fmtIST(new Date())]])}
  ${noticeBar('Never share this code. VIESL staff will never ask you for it. If you did not request a password reset, you can ignore this email \u2014 your password stays unchanged.', '#fdeceb', '#8a2019')}`;
  return {
    subject: 'Your Report Analyzer verification code',
    html: shell({ title: 'Password reset code', preheader: 'Your one-time verification code (valid ' + mins + ' minutes).',
      logoUrl, version, body, accent: 'linear-gradient(90deg,#2f6db0 0%,#5b9bf8 100%)' })
  };
}

// 6. password changed confirmation (queued to the outbox after a successful reset)
function passwordChanged({ name, user_id, when, portalUrl, logoUrl, version }) {
  const body = `
  <tr><td style="padding:30px 28px 0;">
    <div style="font:700 20px/1.35 ${F};color:#12634a;letter-spacing:-.2px;">&#10003; Your password has been changed</div>
    <div style="font:400 14px/1.65 ${F};color:#44586e;padding-top:11px;">
      Hello <b style="color:#12314f;">${esc(name)}</b>,<br><br>
      Your Report Analyzer password was changed successfully. You can now sign in with your new password.
      For your security you have been signed out on all devices.
    </div>
  </td></tr>
  ${detailRows([['Username', user_id], ['Changed on', fmtIST(when || new Date())]])}
  ${noticeBar('If you did not make this change, contact IT Support immediately using the details below.', '#fdeceb', '#8a2019')}
  ${ctaButton(portalUrl, 'Sign in &nbsp;&rarr;', '#1d9e75')}`;
  return {
    subject: 'Your Report Analyzer password was changed',
    html: shell({ title: 'Password changed', preheader: 'Your account password was changed successfully.',
      logoUrl, version, body, accent: 'linear-gradient(90deg,#1d9e75 0%,#4bc79b 100%)' })
  };
}

module.exports = {
  F, BRAND, CONTACTS, esc, nf, fmtIST,
  shell, header, contactCard, footer, ctaButton, detailRows, noticeBar,
  approved, accountCreated, passwordReset, accountLocked,
  passwordOtp, passwordChanged
};

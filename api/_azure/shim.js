// ============================================================================
//  Vercel -> Azure Functions adapter
//
//  WHY THIS EXISTS
//  The three API handlers (ask-hary, forgot-password, send-report-email) are
//  written for Vercel's Node signature:
//
//      module.exports = async (req, res) => { res.status(200).json({...}) }
//
//  Azure Functions v4 instead calls `async (request, context)` and expects an
//  HttpResponseInit to be RETURNED. Rather than fork the three handlers - which
//  would mean fixing every future mail/OTP bug twice, once per branch - this
//  module fakes the Express-ish `req`/`res` pair the handlers already expect and
//  translates the result back into what Azure wants.
//
//  The handler files are therefore BYTE-IDENTICAL on the Vercel branch and the
//  Azure branch. Only this adapter and the wiring in ./routes.js differ.
//
//  Surface actually used by the handlers (checked, not guessed):
//      req.method, req.body, req.headers['x-mail-secret']
//      res.setHeader(k, v), res.status(n).json(obj), res.status(n).end()
//  Everything else below is defensive padding so a future handler does not
//  silently hit an undefined method.
// ============================================================================

'use strict';

/** Azure gives a Headers object; the handlers index it like a plain lowercase map. */
function plainHeaders(h) {
  const out = {};
  if (!h) return out;
  try {
    if (typeof h.entries === 'function') {
      for (const [k, v] of h.entries()) out[String(k).toLowerCase()] = v;
      return out;
    }
  } catch (e) { /* fall through */ }
  try {
    for (const k of Object.keys(h)) out[String(k).toLowerCase()] = h[k];
  } catch (e) { /* ignore */ }
  return out;
}

/** Vercel pre-parses JSON bodies; Azure hands you a stream. Match Vercel. */
async function readBody(request) {
  let raw = '';
  try { raw = await request.text(); } catch (e) { return undefined; }
  if (raw === '' || raw == null) return undefined;

  const ct = String((request.headers && request.headers.get
    ? request.headers.get('content-type')
    : '') || '').toLowerCase();

  if (ct.includes('application/x-www-form-urlencoded')) {
    try { return Object.fromEntries(new URLSearchParams(raw)); } catch (e) { return raw; }
  }
  // Default to JSON, exactly as Vercel does, and fall back to the raw string.
  // The handlers already re-parse a string body, so either shape is safe.
  try { return JSON.parse(raw); } catch (e) { return raw; }
}

function queryOf(request) {
  try {
    if (request.query && typeof request.query.entries === 'function') {
      return Object.fromEntries(request.query.entries());
    }
    return Object.fromEntries(new URL(request.url).searchParams);
  } catch (e) { return {}; }
}

/**
 * Wrap a Vercel-style handler so Azure Functions can invoke it.
 * @param {(req:any, res:any) => Promise<void>} vercelHandler
 * @returns {(request:any, context:any) => Promise<object>} Azure handler
 */
function adapt(vercelHandler) {
  return async function azureHandler(request, context) {
    const out = { status: 200, headers: {}, body: '' };
    let ended = false;

    const res = {
      setHeader(k, v) { out.headers[String(k)] = String(v); return res; },
      getHeader(k) { return out.headers[String(k)]; },
      removeHeader(k) { delete out.headers[String(k)]; return res; },
      status(code) { out.status = Number(code) || 200; return res; },
      json(obj) {
        out.headers['Content-Type'] = 'application/json; charset=utf-8';
        try { out.body = JSON.stringify(obj); } catch (e) { out.body = '{}'; }
        ended = true;
        return res;
      },
      send(payload) {
        if (payload && typeof payload === 'object' && !Buffer.isBuffer(payload)) return res.json(payload);
        out.body = payload == null ? '' : (Buffer.isBuffer(payload) ? payload : String(payload));
        ended = true;
        return res;
      },
      end(payload) {
        if (payload != null) out.body = Buffer.isBuffer(payload) ? payload : String(payload);
        ended = true;
        return res;
      },
      // present so an Express-style handler cannot crash on a missing method
      write(chunk) { out.body = String(out.body || '') + String(chunk == null ? '' : chunk); return res; },
      setHeaders() { return res; },
      get writableEnded() { return ended; },
      get headersSent() { return ended; },
    };

    const req = {
      method: String((request && request.method) || 'GET').toUpperCase(),
      url: (request && request.url) || '',
      headers: plainHeaders(request && request.headers),
      query: queryOf(request),
      body: await readBody(request),
    };

    try {
      await vercelHandler(req, res);
    } catch (err) {
      const msg = (err && err.message) || String(err);
      if (context && typeof context.error === 'function') context.error('Unhandled handler error:', msg);
      return {
        status: 500,
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
        body: JSON.stringify({ ok: false, error: 'Internal server error.' }),
      };
    }

    // A 204 must not carry a body, or Azure rejects the response.
    if (out.status === 204) return { status: 204, headers: out.headers };
    return out;
  };
}

module.exports = { adapt, plainHeaders, readBody };

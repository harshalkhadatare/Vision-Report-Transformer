// ============================================================================
//  Azure Functions v4 entry point for the VIESL Report Analyzer API.
//
//  package.json points "main" here. Every route below reuses the UNMODIFIED
//  Vercel handler, wrapped by ./shim.js, so /api/<name> behaves identically on
//  both deployments.
//
//  Route names match the paths index.html already calls:
//      POST /api/ask-hary            (index.html ~11337)
//      POST /api/forgot-password     (index.html ~4484)
//      POST /api/send-report-email   (index.html ~3741, and Supabase pg_net)
//
//  Static Web Apps always mounts managed functions under /api, so the route
//  value here must NOT include the /api prefix.
// ============================================================================

'use strict';

const { app } = require('@azure/functions');
const { adapt } = require('./shim');

const ROUTES = [
  ['ask-hary', require('../ask-hary.js')],
  ['forgot-password', require('../forgot-password.js')],
  ['send-report-email', require('../send-report-email.js')],
];

for (const [name, handler] of ROUTES) {
  app.http(name, {
    // The handlers answer OPTIONS themselves (204) and reject anything that is
    // not POST, so both verbs are registered and the handler stays in charge.
    methods: ['POST', 'OPTIONS'],
    authLevel: 'anonymous',
    route: name,
    handler: adapt(handler),
  });
}

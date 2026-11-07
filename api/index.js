// Vercel entry: one function serves the whole app. Scheduling comes from vercel.json crons → /api/harness/cron.
const { open } = require('../server/db');
const { createApp } = require('../server/app');
const { createHarness } = require('../harness');
const { createAuth } = require('../server/auth');

let ready;
async function build() {
  if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required on Vercel');
  const db = await open(process.env.DATABASE_URL);
  const harness = createHarness(db, { inProcess: true });
  return createApp(db, harness, { auth: createAuth() });
}
module.exports = async (req, res) => {
  try { ready ||= build(); (await ready)(req, res); }
  catch (e) { ready = null; res.statusCode = 500; res.end('startup error: ' + e.message); }
};

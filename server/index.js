// Local / container entry: long-running server with the interval scheduler.
const { open } = require('./db');
const { createApp } = require('./app');
const { createHarness } = require('../harness');
const { createAuth } = require('./auth');

(async () => {
  const db = await open();
  const harness = createHarness(db);
  const auth = createAuth();
  const app = createApp(db, harness, { auth });
  if (process.env.SEED && (await db.children(null)).length === 0) await require('./seed').seed(db);
  const port = Number(process.env.PORT || 3000);
  app.listen(port, '0.0.0.0', () => {
    console.log(`Schrodinger on http://localhost:${port}  (db: ${process.env.DATABASE_URL ? 'postgres' : 'pglite ' + (process.env.PGLITE_DIR || 'in-memory')}; LLM: ${harness.status().live ? 'Claude API' : 'mock'}; auth: ${auth.enabled ? 'password' : 'OPEN — set APP_PASSWORD before exposing'})`);
    harness.start();
  });
})().catch(e => { console.error(e); process.exit(1); });

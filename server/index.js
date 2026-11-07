const path = require('node:path');
const { open } = require('./db');
const { createApp } = require('./app');
const { createHarness } = require('../harness');

const dbPath = process.env.DB_PATH || path.join(__dirname, '..', 'schrodinger.db');
const db = open(dbPath);
const harness = createHarness(db, { dbPath });
const { createAuth } = require('./auth');
const auth = createAuth();
const app = createApp(db, harness, { auth });

if (process.env.SEED && db.children(null).length === 0) require('./seed').seed(db);

const port = Number(process.env.PORT || 3000);
app.listen(port, '0.0.0.0', () => {
  console.log(`Schrodinger on http://localhost:${port}  (LLM: ${harness.status().live ? 'Claude API' : 'mock'}; auth: ${auth.enabled ? 'password' : 'OPEN — set APP_PASSWORD before exposing'})`);
  harness.start();
});

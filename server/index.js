const path = require('node:path');
const { open } = require('./db');
const { createApp } = require('./app');
const { createHarness } = require('../harness');

const dbPath = process.env.DB_PATH || path.join(__dirname, '..', 'schrodinger.db');
const db = open(dbPath);
const harness = createHarness(db, { dbPath });
const app = createApp(db, harness);

if (process.env.SEED && db.children(null).length === 0) require('./seed').seed(db);

const port = Number(process.env.PORT || 3000);
app.listen(port, () => {
  console.log(`Schrodinger on http://localhost:${port}  (LLM: ${harness.status().live ? 'Claude API' : 'mock'})`);
  harness.start();
});

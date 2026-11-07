// Single-user password gate. Set APP_PASSWORD to enable; unset = open (local dev).
// Session = HMAC-signed cookie; no server-side session store needed.
const crypto = require('node:crypto');

function createAuth({ password = process.env.APP_PASSWORD, secret, maxAgeDays = 30 } = {}) {
  const enabled = !!password;
  secret = secret || process.env.APP_SECRET || password || 'dev';
  const sign = v => crypto.createHmac('sha256', secret).update(v).digest('base64url');
  const token = () => { const exp = String(Date.now() + maxAgeDays * 86400e3); return `${exp}.${sign(exp)}`; };
  const valid = t => {
    if (!t) return false;
    const [exp, sig] = t.split('.');
    if (!exp || !sig) return false;
    const good = sign(exp);
    return sig.length === good.length && crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(good)) && Number(exp) > Date.now();
  };
  const cookies = req => Object.fromEntries((req.headers.cookie || '').split(';').map(c => c.trim().split('=')).filter(([k]) => k));
  const cookieHeader = (v, req) => `sid=${v}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAgeDays * 86400}${req.secure || req.get('x-forwarded-proto') === 'https' ? '; Secure' : ''}`;

  const PUBLIC = new Set(['/login', '/logo.svg', '/healthz']);
  const loginPage = (err = '') => `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Schrodinger</title><link rel="icon" href="/logo.svg">
<style>body{font:15px system-ui,sans-serif;background:#fafaf9;color:#1c1917;display:grid;place-items:center;height:100vh;margin:0}form{background:#fff;border:1px solid #e7e5e4;border-radius:10px;padding:24px;width:300px}img{display:block;margin:0 auto 12px}input{width:100%;box-sizing:border-box;font:inherit;padding:8px;border:1px solid #e7e5e4;border-radius:6px;margin:8px 0}button{width:100%;font:inherit;padding:8px;background:#1c1917;color:#fff;border:0;border-radius:6px}.e{color:#b91c1c;font-size:13px}</style></head>
<body><form method="post" action="/login"><img src="/logo.svg" width="48" height="48"><input type="password" name="password" placeholder="Password" autofocus>${err ? `<div class="e">${err}</div>` : ''}<button>Enter</button></form></body></html>`;

  function middleware(req, res, next) {
    if (!enabled) return next();
    const p = req.path;
    if (p === '/login') {
      if (req.method === 'POST') {
        const given = String(req.body?.password || '');
        const ok = given.length === password.length && crypto.timingSafeEqual(Buffer.from(given), Buffer.from(password));
        if (!ok) return res.status(401).type('html').send(loginPage('Wrong password'));
        res.set('set-cookie', cookieHeader(token(), req));
        return res.redirect('/');
      }
      return res.type('html').send(loginPage());
    }
    if (p === '/logout') { res.set('set-cookie', 'sid=; Path=/; Max-Age=0'); return res.redirect('/login'); }
    if (PUBLIC.has(p) || p.startsWith('/calendar/') || p === '/api/harness/cron') return next(); // ICS feed is token-gated on its own
    if (valid(cookies(req).sid)) return next();
    if (p.startsWith('/api/')) return res.status(401).json({ error: 'unauthorized' });
    return res.redirect('/login');
  }
  return { enabled, middleware, token, valid };
}

module.exports = { createAuth };

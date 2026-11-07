// Calendar hooks.
//  - Outbound: iCal feed of tasks with due dates (subscribe from Google/Apple/Outlook), and a per-task .ics.
//  - Inbound: subscribe to external ICS feeds; events cached in `events`; exposed to UI and sub-agents.
//  - Providers: `ics` implemented. `google`/`caldav` are stubs with the same interface for OAuth adapters later.
const crypto = require('node:crypto');

// ---------- ICS parsing (subset: VEVENT, DTSTART/DTEND/DURATION, SUMMARY, UID, DESCRIPTION, LOCATION, URL) ----------
function unfold(text) { return text.replace(/\r\n[ \t]|\n[ \t]/g, ''); }
function unescapeText(s) { return s.replace(/\\n/gi, '\n').replace(/\\,/g, ',').replace(/\\;/g, ';').replace(/\\\\/g, '\\'); }

function parseDate(value, params = {}) {
  // Returns { iso, all_day }. All-day dates → YYYY-MM-DD. Floating/local times treated as local; Z as UTC.
  const m = value.match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$/);
  if (!m) return null;
  const [, y, mo, d, h, mi, s, z] = m;
  if (params.VALUE === 'DATE' || h === undefined) return { iso: `${y}-${mo}-${d}`, all_day: true };
  const dt = z ? new Date(Date.UTC(+y, mo - 1, +d, +h, +mi, +(s || 0))) : new Date(+y, mo - 1, +d, +h, +mi, +(s || 0));
  return { iso: dt.toISOString(), all_day: false };
}

function parseDuration(v) {
  const m = v.match(/^(-)?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/);
  if (!m) return 0;
  const [, neg, w, d, h, mi, s] = m;
  const ms = ((+w || 0) * 7 * 86400 + (+d || 0) * 86400 + (+h || 0) * 3600 + (+mi || 0) * 60 + (+s || 0)) * 1000;
  return neg ? -ms : ms;
}

function parseICS(text) {
  const lines = unfold(text).split(/\r?\n/);
  const events = []; let cur = null;
  for (const line of lines) {
    if (line === 'BEGIN:VEVENT') { cur = {}; continue; }
    if (line === 'END:VEVENT') { if (cur) events.push(cur); cur = null; continue; }
    if (!cur) continue;
    const idx = line.indexOf(':'); if (idx < 0) continue;
    const left = line.slice(0, idx), value = line.slice(idx + 1);
    const [name, ...pp] = left.split(';');
    const params = Object.fromEntries(pp.map(p => p.split('=')));
    switch (name) {
      case 'UID': cur.uid = value; break;
      case 'SUMMARY': cur.title = unescapeText(value); break;
      case 'DESCRIPTION': cur.description = unescapeText(value); break;
      case 'LOCATION': cur.location = unescapeText(value); break;
      case 'URL': cur.url = value; break;
      case 'DTSTART': { const p = parseDate(value, params); if (p) { cur.start = p.iso; cur.all_day = p.all_day; } break; }
      case 'DTEND': { const p = parseDate(value, params); if (p) cur.end = p.iso; break; }
      case 'DURATION': cur._duration = parseDuration(value); break;
      case 'RRULE': cur.recurring = true; break;
      case 'STATUS': cur.status = value; break;
    }
  }
  return events.filter(e => e.start).map(e => {
    if (!e.end) {
      if (e._duration) e.end = new Date(new Date(e.start).getTime() + e._duration).toISOString();
      else if (e.all_day) e.end = e.start;
      else e.end = new Date(new Date(e.start).getTime() + 3600e3).toISOString();
    }
    delete e._duration;
    e.uid = e.uid || crypto.createHash('sha1').update(`${e.title}|${e.start}`).digest('hex');
    e.title = e.title || '(untitled)';
    return e;
  });
}

// ---------- ICS generation ----------
function icsEscape(s) { return String(s ?? '').replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n'); }
function fold(line) { const out = []; let s = line; while (s.length > 73) { out.push(s.slice(0, 73)); s = ' ' + s.slice(73); } out.push(s); return out.join('\r\n'); }
function dateOnly(iso) { return iso.slice(0, 10).replace(/-/g, ''); }
function stampUTC(d = new Date()) { return d.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z'); }

function taskToVevent(task, project, baseUrl = '') {
  // Tasks are due on a date → all-day event on that date.
  const due = task.due; if (!due) return null;
  const next = new Date(due + 'T00:00:00Z'); next.setUTCDate(next.getUTCDate() + 1);
  const lines = [
    'BEGIN:VEVENT',
    `UID:schrodinger-task-${task.id}`,
    `DTSTAMP:${stampUTC(new Date(task.updated_at || Date.now()))}`,
    `DTSTART;VALUE=DATE:${dateOnly(due)}`,
    `DTEND;VALUE=DATE:${dateOnly(next.toISOString())}`,
    `SUMMARY:${icsEscape(`${task.state === 'done' ? '✓ ' : ''}${task.title}${task.assignee === 'ai' ? ' (AI)' : ''}`)}`,
    `DESCRIPTION:${icsEscape(`Project: ${project?.title || ''}\nMode: ${task.mode || '-'}\nAssignee: ${task.assignee}\nState: ${task.state}${baseUrl ? `\n${baseUrl}/#${task.id}` : ''}`)}`,
    `CATEGORIES:${['Schrodinger', project?.title, task.mode].filter(Boolean).map(icsEscape).join(',')}`,
    task.state === 'done' ? 'STATUS:CONFIRMED' : 'STATUS:TENTATIVE',
    'END:VEVENT',
  ];
  return lines.map(fold).join('\r\n');
}

function buildCalendar(vevents, name = 'Schrodinger') {
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Schrodinger//EN', 'CALSCALE:GREGORIAN', `X-WR-CALNAME:${icsEscape(name)}`, ...vevents, 'END:VCALENDAR', ''].join('\r\n');
}

// ---------- Providers ----------
// Interface: { kind, async fetchEvents(calendarRow) → [{uid,title,start,end,all_day,description,location,url,recurring,status}] }
const providers = {
  ics: {
    kind: 'ics',
    async fetchEvents(cal, { fetchImpl = fetch } = {}) {
      const r = await fetchImpl(cal.url.replace(/^webcal:/, 'https:'), { headers: { 'user-agent': 'schrodinger/0.1' }, redirect: 'follow' });
      if (!r.ok) throw new Error(`fetch failed: ${r.status}`);
      return parseICS(await r.text());
    },
  },
  google: {
    kind: 'google',
    async fetchEvents() { throw new Error('google provider not configured: use the calendar\'s secret iCal address with kind=ics, or implement OAuth in server/calendar.js providers.google'); },
  },
  caldav: {
    kind: 'caldav',
    async fetchEvents() { throw new Error('caldav provider not implemented: use an ICS export URL with kind=ics'); },
  },
};

module.exports = { parseICS, parseDate, taskToVevent, buildCalendar, providers, icsEscape };

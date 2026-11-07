// Tools available to a project sub-agent. Draft-only by construction: there is no tool that sends,
// posts, commits, or contacts anyone. File tools are jailed to the project's own workspace (stored in the `files` table).
const path = require('node:path');

const MAX_FETCH_BYTES = 200_000;
const MAX_FILE_BYTES = 500_000;

function makeTools({ db, project, task }) {
  // Normalize a workspace-relative path; reject escapes and absolute paths.
  const safe = rel => {
    const raw = String(rel || '').replace(/\\/g, '/');
    if (!raw || raw.startsWith('/') || /^[a-zA-Z]:/.test(raw) || raw.split('/').includes('..')) throw new Error('path escapes project workspace');
    const p = path.posix.normalize(raw);
    if (!p || p === '.' || p.startsWith('../')) throw new Error('path escapes project workspace');
    return p;
  };

  const defs = [
    { name: 'project_context', description: 'Get the project goal, success criteria, constraints, and all tasks with their state, assignee, mode, due date, acceptance notes and existing artifacts.', input_schema: { type: 'object', properties: {} } },
    { name: 'web_fetch', description: 'Fetch a public URL and return its text content (HTML tags stripped, truncated). Read-only.', input_schema: { type: 'object', properties: { url: { type: 'string' } }, required: ['url'] } },
    { name: 'list_files', description: 'List files in this project\'s workspace.', input_schema: { type: 'object', properties: { subdir: { type: 'string' } } } },
    { name: 'read_file', description: 'Read a text file from this project\'s workspace.', input_schema: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } },
    { name: 'write_file', description: 'Write a text file into this project\'s workspace (drafts, notes, data). Overwrites.', input_schema: { type: 'object', properties: { path: { type: 'string' }, content: { type: 'string' } }, required: ['path', 'content'] } },
    { name: 'calendar_events', description: 'List calendar events (from the owner\'s subscribed calendars) between two ISO dates. Defaults: today → +14 days. Read-only.', input_schema: { type: 'object', properties: { from: { type: 'string' }, to: { type: 'string' } } } },
    { name: 'finish', description: 'Submit the final draft for human review. Call exactly once when done.', input_schema: { type: 'object', properties: { artifact: { type: 'string', description: 'The deliverable text, markdown.' }, needs_from_human: { type: 'array', items: { type: 'string' } } }, required: ['artifact'] } },
  ];

  const handlers = {
    async project_context() {
      const tasks = (await db.descendants(project.id)).map(t => ({ id: t.id, title: t.title, assignee: t.assignee, state: t.state, mode: t.mode, due: t.due, acceptance_note: t.acceptance_note || undefined, artifact: t.artifact ? t.artifact.slice(0, 2000) : undefined, parent_id: t.parent_id === project.id ? undefined : t.parent_id }));
      return { project: { title: project.title, goal: project.goal, success_criteria: project.success_criteria, constraints: project.constraints }, current_task_id: task.id, tasks };
    },
    async web_fetch({ url }) {
      const u = new URL(url);
      if (!/^https?:$/.test(u.protocol)) throw new Error('http(s) only');
      const ctrl = new AbortController(); const to = setTimeout(() => ctrl.abort(), 20_000);
      try {
        const r = await fetch(u, { signal: ctrl.signal, redirect: 'follow', headers: { 'user-agent': 'schrodinger-agent/0.1' } });
        const ct = r.headers.get('content-type') || '';
        let text = await r.text();
        if (/html/.test(ct)) text = text.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/gi, '').replace(/<[^>]+>/g, ' ').replace(/&nbsp;|&#160;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/[ \t]+/g, ' ').replace(/\n\s*\n+/g, '\n');
        if (text.length > MAX_FETCH_BYTES) text = text.slice(0, MAX_FETCH_BYTES) + '\n[truncated]';
        return { status: r.status, content_type: ct, text };
      } finally { clearTimeout(to); }
    },
    async list_files({ subdir } = {}) {
      const files = await db.fileList(project.id);
      const pre = subdir ? safe(subdir).replace(/\/?$/, '/') : '';
      return { files: files.filter(f => f.path.startsWith(pre)) };
    },
    async read_file({ path: rel }) {
      const p = safe(rel);
      const content = await db.fileRead(project.id, p);
      if (content === null) throw new Error('no such file');
      return { path: p, content };
    },
    async write_file({ path: rel, content }) {
      const p = safe(rel);
      if (Buffer.byteLength(content) > MAX_FILE_BYTES) throw new Error('content too large');
      await db.fileWrite(project.id, p, content);
      return { path: p, bytes: Buffer.byteLength(content) };
    },
    async calendar_events({ from, to } = {}) {
      return { events: (await db.events({ from, to, project_id: project.id })).map(e => ({ title: e.title, start: e.start, end: e.end, all_day: !!e.all_day, location: e.location || undefined, calendar: e.calendar_name })) };
    },
    finish({ artifact, needs_from_human }) {
      return { done: true, artifact: needs_from_human?.length ? `${artifact}\n\n## Needs from you\n${needs_from_human.map(s => `- ${s}`).join('\n')}` : artifact };
    },
  };

  async function call(name, input) {
    if (!handlers[name]) throw new Error(`unknown tool ${name}`);
    return handlers[name](input || {});
  }

  return { defs, call };
}

module.exports = { makeTools };

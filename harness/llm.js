// LLM adapter. Uses the Claude API when ANTHROPIC_API_KEY is set; otherwise a deterministic mock
// so the harness is testable offline. Draft-only: output is text attached to the task, never sent anywhere.

const MODEL = process.env.CLAUDE_MODEL || 'claude-sonnet-4-5';

function systemPrompt(project) {
  return [
    `You are the sub-agent for the project "${project.title}".`,
    `Goal: ${project.goal || '(none stated)'}`,
    `Success criteria: ${project.success_criteria || '(none stated)'}`,
    `Constraints: ${project.constraints || '(none)'}`,
    `Rules: You produce drafts only. You never send email, post, commit, or contact anyone.`,
    `Everything you write is reviewed by the human owner before it is used.`,
    `Be concise and concrete.`,
  ].join('\n');
}

async function callClaude(system, user, maxTokens = 1500) {
  const Anthropic = require('@anthropic-ai/sdk');
  const client = new Anthropic();
  const resp = await client.messages.create({
    model: MODEL, max_tokens: maxTokens, system,
    messages: [{ role: 'user', content: user }],
  });
  return resp.content.filter(c => c.type === 'text').map(c => c.text).join('\n');
}

const live = () => !!process.env.ANTHROPIC_API_KEY && !process.env.HARNESS_MOCK;

// ---- Draft a task deliverable (agentic tool loop) --------------------------
const MAX_TURNS = Number(process.env.AGENT_MAX_TURNS || 12);

// `model` is a function(messages, toolDefs) → { stop_reason, content } mirroring the Messages API shape.
// Live mode uses Claude; mock mode uses a scripted model so the loop is exercised offline.
async function draft({ db, project, task, siblings, rejectionNotes, model, shared = false }) {
  const { makeTools } = require('./tools');
  const tools = makeTools({ db, project, task });
  const run = model || (live() ? claudeModel(systemPrompt(project)) : mockModel({ project, task, rejectionNotes }));
  const user = [
    `Task: ${task.title}`,
    task.mode ? `Mode: ${task.mode}` : '',
    task.due ? `Due: ${task.due}` : '',
    rejectionNotes ? `Prior review notes from the owner (address these):\n${rejectionNotes}` : '',
    shared ? `This task is SHARED: you do the preparatory part (research, drafting, checklists, materials) and the owner finishes it in person. Produce everything the owner needs to complete their part, and state clearly what remains for them.` : '',
    `Use project_context first. Use web_fetch for anything factual you are not sure of. Save working notes with write_file. When the deliverable is ready, call finish with the full draft. If the task needs information only the owner has, draft what you can and list the questions in needs_from_human.`,
  ].filter(Boolean).join('\n\n');
  const messages = [{ role: 'user', content: user }];
  const log = [];
  for (let turn = 0; turn < MAX_TURNS; turn++) {
    const resp = await run(messages, tools.defs);
    messages.push({ role: 'assistant', content: resp.content });
    const uses = resp.content.filter(c => c.type === 'tool_use');
    if (!uses.length) {
      const text = resp.content.filter(c => c.type === 'text').map(c => c.text).join('\n').trim();
      return { artifact: text || '(agent returned no draft)', log };
    }
    const results = [];
    for (const u of uses) {
      let out, is_error = false;
      try { out = await tools.call(u.name, u.input); } catch (e) { out = { error: e.message }; is_error = true; }
      log.push(`${u.name}(${JSON.stringify(u.input).slice(0, 120)}) → ${is_error ? 'error: ' + out.error : 'ok'}`);
      if (u.name === 'finish' && !is_error) return { artifact: out.artifact, log };
      results.push({ type: 'tool_result', tool_use_id: u.id, content: JSON.stringify(out).slice(0, 60_000), is_error });
    }
    messages.push({ role: 'user', content: results });
  }
  return { artifact: `(agent hit the ${MAX_TURNS}-turn limit without calling finish)\n\nTool log:\n${log.join('\n')}`, log };
}

function claudeModel(system) {
  const Anthropic = require('@anthropic-ai/sdk');
  const client = new Anthropic();
  return async (messages, tools) => client.messages.create({ model: MODEL, max_tokens: 4000, system, tools, messages });
}

// Scripted model: project_context → write_file notes → finish. Deterministic, no network.
function mockModel({ project, task, rejectionNotes }) {
  let step = 0;
  return async () => {
    step++;
    const tu = (name, input) => ({ type: 'tool_use', id: `mock_${step}`, name, input });
    if (step === 1) return { stop_reason: 'tool_use', content: [{ type: 'text', text: 'Reading project context.' }, tu('project_context', {})] };
    if (step === 2) return { stop_reason: 'tool_use', content: [tu('write_file', { path: `notes/${task.id}.md`, content: `# Notes for ${task.title}\n- goal: ${project.goal}\n` })] };
    return { stop_reason: 'tool_use', content: [tu('finish', { artifact: mockDraft({ project, task, rejectionNotes }), needs_from_human: ['Confirm scope and any constraints not listed in the project.'] })] };
  };
}

function mockDraft({ project, task, rejectionNotes }) {
  return [
    `# Draft: ${task.title}`,
    ``,
    `Project: ${project.title}`,
    `Goal alignment: ${project.goal ? `supports "${project.goal}"` : 'no project goal stated'}`,
    ``,
    `## Content`,
    `1. Scope the work: ${task.title}.`,
    `2. Identify inputs and owners.`,
    `3. Produce the deliverable.`,
    rejectionNotes ? `\n## Revisions addressing review notes\n${rejectionNotes}` : '',
    ``,
    `_(mock draft — set ANTHROPIC_API_KEY for real output)_`,
  ].join('\n');
}

// ---- Analyze project, return proposals -----------------------------------
// Returns array of { type, node_id, summary, payload }
async function analyze({ project, tasks, progress }) {
  const heuristics = heuristicProposals({ project, tasks, progress });
  if (!live()) return heuristics;
  const user = [
    `Open tasks (JSON): ${JSON.stringify(tasks.filter(t => t.state !== 'done').map(t => ({ id: t.id, title: t.title, assignee: t.assignee, state: t.state, due: t.due, has_children: t.has_children })))}`,
    `Progress: ${progress.done}/${progress.total} leaf tasks done.`,
    `Return ONLY a JSON array. Each item: {"type":"decompose"|"new_task"|"reassign","node_id":string|null,"summary":string,"payload":object}.`,
    `- decompose: payload {"subtasks":[{"title","assignee":"ai"|"human"}]} for a task too large to execute in one step.`,
    `- new_task: payload {"title","assignee"} when the goal has no task path to completion.`,
    `- reassign: payload {"assignee"} when a task is misassigned (e.g. AI cannot do it draft-only, or it is pure drafting the human assigned to themselves).`,
    `Return [] if nothing is needed. Max 5 items.`,
  ].join('\n\n');
  try {
    const text = await callClaude(systemPrompt(project), user, 1200);
    const m = text.match(/\[[\s\S]*\]/);
    const arr = m ? JSON.parse(m[0]) : [];
    return [...heuristics, ...arr.filter(p => p && p.type && p.summary)];
  } catch { return heuristics; }
}

function heuristicProposals({ project, tasks, progress }) {
  const out = [];
  const open = tasks.filter(t => t.state !== 'done');
  if (tasks.length > 0 && open.length === 0 && progress.pct < 100) {
    out.push({ type: 'no_path', node_id: null, summary: `No open tasks but goal not complete — add tasks toward: ${project.goal || project.title}`, payload: {} });
  }
  if (tasks.length === 0) {
    out.push({ type: 'new_task', node_id: null, summary: `Project has no tasks. Suggest: "Define first milestone for ${project.title}"`, payload: { title: `Define first milestone for ${project.title}`, assignee: 'human' } });
  }
  for (const t of open) {
    if (!t.has_children && t.assignee === 'ai' && t.state === 'todo' && (t.title.length > 70 || /\band\b/i.test(t.title))) {
      const parts = t.title.split(/\band\b/i).map(s => s.trim()).filter(Boolean);
      out.push({ type: 'decompose', node_id: t.id, summary: `"${t.title}" looks like more than one step — split it?`,
        payload: { subtasks: (parts.length > 1 ? parts : [t.title + ' — part 1', t.title + ' — part 2']).map(title => ({ title, assignee: 'ai' })) } });
    }
  }
  return out;
}

module.exports = { draft, analyze, live, claudeModel, mockModel };

// Sample data. Generic content; replace with your own projects.
function seed(db) {
  const p1 = db.createNode({ title: 'Launch newsletter', goal: 'Publish a monthly newsletter to subscribers starting next month.', success_criteria: 'First issue sent; 3 issues outlined; signup form live.' });
  const outline = db.createNode({ parent_id: p1.id, title: 'Outline first three issues', assignee: 'ai' });
  const draft1 = db.createNode({ parent_id: p1.id, title: 'Draft issue 1', assignee: 'ai', deps: [outline.id] });
  db.createNode({ parent_id: p1.id, title: 'Pick email provider', assignee: 'human', mode: 'research', due: new Date(Date.now() + 3 * 86400e3).toISOString().slice(0, 10) });
  db.createNode({ parent_id: p1.id, title: 'Review and send issue 1', assignee: 'human', mode: 'email', deps: [draft1.id] });

  const p2 = db.createNode({ title: 'Grant application', goal: 'Submit a complete application before the deadline.', success_criteria: 'Narrative, budget, and attachments submitted.', constraints: 'No outreach to the funder without approval.' });
  db.createNode({ parent_id: p2.id, title: 'Research eligibility requirements and summarize budget rules', assignee: 'ai' });
  db.createNode({ parent_id: p2.id, title: 'Draft narrative section', assignee: 'ai' });
  db.createNode({ parent_id: p2.id, title: 'Gather financial statements', assignee: 'human', mode: 'errand' });

  db.createNode({ parent_id: p2.id, title: 'Call program officer re: deadline', assignee: 'human', mode: 'call' });
  db.createNode({ parent_id: p1.id, title: 'Call designer about masthead', assignee: 'human', mode: 'call' });

  db.createNode({ title: 'Empty project', goal: 'Demonstrates the no-tasks proposal.' });
}
module.exports = { seed };

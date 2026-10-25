const { test } = require('node:test');
const assert = require('node:assert/strict');
const { validateRequest, assessEvidence, renderReport, parseAnalysis, verifyToolEvidence, verifyHead } = require('../workflow/logic.cjs');
const release = { release_id: 'shop-ready', base_revision: 'a'.repeat(40), target_revision: 'b'.repeat(40), evidence_path:'/data/evidence/shop-ready.json' };
const evidence = () => ({ ...release, checks: { tests: 'passed', image_scan: 'passed', migration_review: 'passed' } });

test('webhook validates identifiers, extra fields and unknown releases', () => {
  const catalog = { 'shop-ready': release };
  assert.equal(validateRequest({ release_id: 'shop-ready' }, catalog).release_id, 'shop-ready');
  for (const body of [null, [], {}, { release_id: '../secret' }, { release_id: 'a\n' }, { release_id: 'a\r' }, { release_id: 'a\u2028' }, { release_id: 'x'.repeat(65) }, { release_id: 'shop-ready', path: '/etc/passwd' }]) {
    assert.equal(validateRequest(body, catalog).code, 400);
  }
  assert.equal(validateRequest({ release_id: 'missing' }, catalog).code, 404);
});

test('release readiness follows evidence, including missing and mismatched data', () => {
  assert.equal(assessEvidence(evidence(), release).status, 'ready');
  const failed = evidence(); failed.checks.tests = 'failed';
  assert.equal(assessEvidence(failed, release).status, 'blocked');
  for (const bad of [null, {}, { ...evidence(), target_revision: 'c'.repeat(40) }, { ...evidence(), checks: {} }]) {
    assert.equal(assessEvidence(bad, release).status, 'incomplete');
  }
  const unknown = evidence(); unknown.checks.image_scan = 'unknown';
  assert.equal(assessEvidence(unknown, release).status, 'incomplete');
  failed.checks.image_scan = 'unknown';
  assert.equal(assessEvidence(failed, release).status, 'blocked');
});

test('invalid agent output is refused; factual report retains deterministic status', () => {
  assert.throws(() => parseAnalysis('looks fine'));
  assert.throws(() => parseAnalysis('{"changes":[]}'));
  const analysis = parseAnalysis('{"changes":["Retry timeout increased"],"risks":[],"unknown":[],"sources":["git:abc"]}');
  const report = renderReport(release, assessEvidence(evidence(), release), analysis);
  for (const heading of ['Релиз', 'Статус', 'Изменения', 'Блокеры', 'Неизвестное', 'Источники']) {
    assert.ok(report.includes('## ' + heading));
  }
  assert.ok(report.includes('ready'));
  assert.ok(report.includes(release.target_revision));
});

test('required MCP tools accept n8n-qualified names and reject missing calls', () => {
  const steps = [
    {action:{tool:'Git_MCP_tools_git_diff',toolInput:{repo_path:'/data/repository',target:release.base_revision}},observation:JSON.stringify([{type:'text',text:`Diff with ${release.base_revision}:\n+change`}])},
    {action:{tool:'Filesystem_MCP_tools_read_text_file',toolInput:{path:release.evidence_path}},observation:JSON.stringify({content:'evidence'})}
  ];
  verifyToolEvidence(steps,release);
  assert.throws(()=>verifyToolEvidence(steps.slice(0,1),release));
  assert.throws(()=>verifyToolEvidence([],release));
  for (const mutate of [
    s=>s[0].action.toolInput.target='wrong',
    s=>s[0].observation='Error: bad revision',
    s=>s[0].observation=JSON.stringify({isError:true}),
    s=>s[1].action.toolInput.path='/data/reports/unrelated.md',
    s=>s[1].action.toolInput.head=1,
    s=>s[1].observation=JSON.stringify({content:''})
  ]) {
    const bad=structuredClone(steps); mutate(bad);
    assert.throws(()=>verifyToolEvidence(bad,release));
  }
});

test('HEAD must equal the leading commit SHA, even when the message mentions the target', () => {
  verifyHead(`commit ${release.target_revision}\nAuthor: Shop CI`,release.target_revision);
  assert.throws(()=>verifyHead(`commit ${'c'.repeat(40)}\nReference ${release.target_revision}`,release.target_revision));
  assert.throws(()=>verifyHead('Error: revision unavailable',release.target_revision));
});

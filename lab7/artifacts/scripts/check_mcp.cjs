const assert = require('node:assert/strict');
const fs = require('node:fs');
const { verifyHead } = require('/lab/workflow/logic.cjs');
const catalog = JSON.parse(fs.readFileSync('/lab/fixtures/catalog.json', 'utf8'));
let id = 0;
async function rpc(server, method, params = {}) {
  const response = await fetch(`http://${server}:8000/${server === 'git-mcp' ? 'git' : 'files'}/mcp`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }), signal: AbortSignal.timeout(30000)
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${response.status}: ${text}`);
  return JSON.parse(text.startsWith('event:') || text.startsWith('data:')
    ? text.split('\n').filter(x => x.startsWith('data:')).at(-1).slice(5).trim() : text);
}
(async () => {
  for (const [server, expected] of [['git-mcp', ['git_log','git_show','git_diff']], ['filesystem-mcp',['read_text_file','write_file']]]) {
    const result = await rpc(server, 'tools/list');
    assert.deepEqual(result.result.tools.map(t=>t.name).sort(), expected.sort());
    console.log(`PASS ${server}: exact tool allowlist`);
  }
  const release = catalog['shop-ready'];
  const log = await rpc('git-mcp','tools/call',{name:'git_log',arguments:{repo_path:'/data/repository',max_count:2}});
  assert.ok(!log.error && !log.result.isError && JSON.stringify(log).includes(release.target_revision));
  const head = await rpc('git-mcp','tools/call',{name:'git_show',arguments:{repo_path:'/data/repository',revision:'HEAD'}});
  verifyHead(head.result.content.find(item=>item.type==='text')?.text, release.target_revision);
  const diff = await rpc('git-mcp','tools/call',{name:'git_diff',arguments:{repo_path:'/data/repository',target:release.base_revision}});
  assert.ok(!diff.error && !diff.result.isError, JSON.stringify(diff));
  assert.ok(JSON.stringify(diff).includes('ORDER_TIMEOUT_SECONDS'));
  const read = await rpc('filesystem-mcp','tools/call',{name:'read_text_file',arguments:{path:release.evidence_path}});
  assert.ok(JSON.stringify(read).includes('passed'));
  const denied = await rpc('filesystem-mcp','tools/call',{name:'read_text_file',arguments:{path:'/etc/passwd'}});
  assert.ok(denied.error || denied.result.isError, 'Filesystem escape must fail');
  const readOnly = await rpc('filesystem-mcp','tools/call',{name:'write_file',arguments:{path:'/data/evidence/write-probe.txt',content:'This must be denied by the read-only mount.'}});
  assert.ok(readOnly.error || readOnly.result.isError, 'Evidence mount must be read-only');
  const blocked = await rpc('git-mcp','tools/call',{name:'git_commit',arguments:{repo_path:'/data/repository',message:'Forbidden'}});
  assert.ok(blocked.error, 'Git mutation must not be exposed');
  console.log('PASS real Git diff, evidence read, filesystem boundary and denied Git mutation');
})().catch(error => { console.error(error); process.exitCode = 1; });

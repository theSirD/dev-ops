"""Generate an importable n8n workflow from tested logic, fixtures and the skill."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    logic = (ROOT / 'workflow/logic.cjs').read_text(encoding='utf-8').split('module.exports =')[0]
    catalog = json.loads((ROOT / 'fixtures/catalog.json').read_text(encoding='utf-8'))
    skill = (ROOT / 'skills/release-review.md').read_text(encoding='utf-8')
    nodes, connections = [], {}

    def node(name, kind, parameters, x, y=0, version=1, **extra):
        item = dict(id=name.lower().replace(' ', '-'), name=name, type=kind, typeVersion=version,
                    position=[x, y], parameters=parameters, **extra)
        nodes.append(item)
        return name

    def link(source, target, output=0, kind='main'):
        outputs = connections.setdefault(source, {}).setdefault(kind, [])
        while len(outputs) <= output:
            outputs.append([])
        outputs[output].append(dict(node=target, type=kind, index=0))

    def code(name, source, x, y=0, failure=False):
        node(name, 'n8n-nodes-base.code', {'jsCode': source}, x, y, version=2,
             **({'onError': 'continueErrorOutput'} if failure else {}))
        if failure:
            link(name, 'Analysis failed', 1)

    def mcp(name, tool, arguments, x, server='filesystem-mcp', route='files'):
        node(name, '@n8n/n8n-nodes-langchain.mcpClient', dict(
            endpointUrl=f'http://{server}:8000/{route}/mcp', serverTransport='httpStreamable',
            authentication='none', tool={'mode': 'id', 'value': tool}, inputMode='json',
            jsonInput=arguments, options={'timeout': 30000}), x, version=1.1, onError='continueErrorOutput')
        link(name, 'Analysis failed', 1)

    node('Release webhook', 'n8n-nodes-base.webhook', dict(httpMethod='POST', path='release-readiness',
         responseMode='responseNode', options={'binaryData':True}), 0, version=1, webhookId='lab8-release-readiness')
    code('Validate release', logic + '\nconst catalog = ' + json.dumps(catalog) + ''';
let body=null;
try { body=JSON.parse((await this.helpers.getBinaryDataBuffer(0,'data')).toString('utf8')); } catch {}
return [{json:validateRequest(body,catalog)}];
''', 230)
    node('Valid request', 'n8n-nodes-base.if', {'conditions': {'options': {'caseSensitive': True, 'typeValidation': 'strict'},
         'conditions': [{'id': 'valid', 'leftValue': '={{ $json.code === undefined }}', 'rightValue': True,
                         'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
         'combinator': 'and'}, 'options': {}}, 460, version=2.2)
    mcp('Read evidence', 'read_text_file', '={{ {path: $json.evidence_path} }}', 690)
    mcp('Check release target', 'git_show', '={{ {repo_path:"/data/repository",revision:"HEAD"} }}', 800, 'git-mcp', 'git')
    code('Assess checks', logic + '''
const release = $('Validate release').first().json;
if (!$('Read evidence').first().json.content?.some(c=>c.type==='text')) throw new Error('MCP evidence collection failed.');
const head=$json.content?.find(c=>c.type==='text')?.text;
verifyHead(head,release.target_revision);
let evidence = $('Read evidence').first().json.content?.find(c=>c.type==='text')?.text;
if (typeof evidence === 'string') { try { evidence=JSON.parse(evidence); } catch { evidence=null; } }
return [{json:{...release, assessment:assessEvidence(evidence,release)}}];
''', 920, failure=True)
    node('Release AI Agent', '@n8n/n8n-nodes-langchain.agent', dict(promptType='define',
         text='={{ "Analyze this release. Read the evidence file and inspect the exact Git range with tools. Return JSON only. " + JSON.stringify($json) }}',
         options={'systemMessage': skill, 'maxIterations': 8, 'returnIntermediateSteps': True}),
         1160, version=2.2, onError='continueErrorOutput')
    link('Release AI Agent', 'Analysis failed', 1)
    node('Local Qwen3', '@n8n/n8n-nodes-langchain.lmChatOllama', dict(model='qwen3:4b-instruct-2507-q4_K_M',
         options={'temperature': 0, 'numCtx': 4096, 'numPredict': 1000}), 1050, 270,
         credentials={'ollamaApi': {'id': 'lab8-ollama', 'name': 'Lab8 local Ollama'}})
    for name, endpoint, tools, x in [
        ('Git MCP tools', 'http://git-mcp:8000/git-sse/sse', ['git_log', 'git_show', 'git_diff'], 1280),
        ('Filesystem MCP tools', 'http://filesystem-mcp:8000/files-sse/sse', ['read_text_file', 'write_file'], 1510)]:
        node(name, '@n8n/n8n-nodes-langchain.mcpClientTool', dict(sseEndpoint=endpoint,
             authentication='none', include='selected', includeTools=tools, options={'timeout':30000}), x, 270)
        link(name, 'Release AI Agent', kind='ai_tool')
    link('Local Qwen3', 'Release AI Agent', kind='ai_languageModel')
    code('Build report', logic + '''
const release = $('Assess checks').first().json;
verifyToolEvidence($json.intermediateSteps || [],release);
const analysis = parseAnalysis($json.output);
const assessment = {...release.assessment};
return [{json:{release_id:release.release_id,status:assessment.status,
  report_path:`/data/reports/${release.release_id}-${$execution.id}.md`,
  report:renderReport(release,assessment,analysis)}}];
''', 1410, failure=True)
    mcp('Save report', 'write_file', '={{ {path: $json.report_path, content: $json.report} }}', 1650)
    mcp('Read saved report', 'read_text_file', '={{ {path: $("Build report").first().json.report_path} }}', 1880)
    code('Verify saved report', '''
const expected=$('Build report').first().json;
if (!$('Save report').first().json.content?.some(c=>c.type==='text')) throw new Error('MCP write failed.');
const actual=$json.content?.find(c=>c.type==='text')?.text;
if(actual!==expected.report) throw new Error('Persisted report differs from expected content.');
return [{json:expected}];
''', 2110, failure=True)
    node('Report response', 'n8n-nodes-base.respondToWebhook', dict(respondWith='json',
         responseBody='={{ $json }}', options={'responseCode':200}), 2340, version=1.4)
    code('Analysis failed', "return [{json:{code:502,error:'analysis_failed',message:'Analysis or report persistence failed. Check the execution history.'}}];", 1650, 560)
    node('Error response', 'n8n-nodes-base.respondToWebhook', dict(respondWith='json',
         responseBody='={{ {error:$json.error,message:$json.message} }}', options={'responseCode':'={{ $json.code }}'}), 1890, 560, version=1.4)
    node('Mark execution failed', 'n8n-nodes-base.stopAndError', dict(errorType='errorMessage',
         errorMessage='={{ $json.error || "Release request failed" }}'), 2120, 560)
    for source,target in zip(['Release webhook','Validate release','Valid request','Read evidence','Check release target','Assess checks','Release AI Agent','Build report','Save report','Read saved report','Verify saved report'],
                             ['Validate release','Valid request','Read evidence','Check release target','Assess checks','Release AI Agent','Build report','Save report','Read saved report','Verify saved report','Report response']):
        link(source,target)
    link('Valid request','Error response',1)
    link('Analysis failed','Error response')
    link('Error response','Mark execution failed')
    workflow = dict(id='lab8-release-readiness',name='Shop release readiness — local AI + MCP',active=False,
                    nodes=nodes,connections=connections,settings={'executionOrder':'v1','executionTimeout':300,
                    'saveDataSuccessExecution':'all','saveDataErrorExecution':'all'})
    assert len({n['name'] for n in nodes}) == len(nodes)
    assert all(edge['node'] in {n['name'] for n in nodes} for outputs in connections.values() for branches in outputs.values() for branch in branches for edge in branch)
    (ROOT/'workflow.json').write_text(json.dumps(workflow,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    credentials=[dict(id='lab8-ollama',name='Lab8 local Ollama',type='ollamaApi',data={'baseUrl':'http://ollama:11434'})]
    (ROOT/'ollama-credential.json').write_text(json.dumps(credentials,indent=2)+'\n',encoding='utf-8')
    print(f'Generated workflow: {len(nodes)} nodes; five MCP tools; local Ollama credential without secrets.')


if __name__=='__main__':
    main()

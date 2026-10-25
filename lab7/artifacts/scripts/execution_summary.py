"""Read execution evidence from n8n without copying account credentials into reports."""
import json
import sys
from n8n_local import connect


def unflatten(text):
    table, memo = json.loads(text), {}
    def resolve(index):
        if index in memo:
            return memo[index]
        value = table[index]
        if not isinstance(value, (dict,list)):
            return value
        result = {} if isinstance(value,dict) else []
        memo[index] = result
        def entry(item):
            return resolve(int(item)) if isinstance(item,str) else item
        if isinstance(value,dict):
            result.update({key:entry(item) for key,item in value.items()})
        else:
            result.extend(entry(item) for item in value)
        return result
    return resolve(0)


assert unflatten('[{"answer":"1"},"42"]') == {'answer':'42'}

if __name__=='__main__':
    request=connect()
    execution_id=sys.argv[1] if len(sys.argv)>1 else request('/rest/executions?limit=1')['data']['results'][0]['id']
    execution=request('/rest/executions/'+execution_id)['data']
    result=unflatten(execution['data'])['resultData']
    summary=dict(id=execution_id,status=execution['status'],nodes={})
    for name,runs in result['runData'].items():
        run=runs[-1]
        items=run.get('data',{}).get('main',[[]])[0]
        data=items[0].get('json',{}) if items else {}
        details={'status':run.get('executionStatus'),'milliseconds':run.get('executionTime')}
        if 'error' in data:
            details['error']=data['error']
        if 'intermediateSteps' in data:
            details['tools']=[step.get('action',{}).get('tool') for step in data['intermediateSteps']]
            details['output']=data.get('output')
        if 'assessment' in data:
            details['assessment']=data['assessment']
        summary['nodes'][name]=details
    print(json.dumps(summary,ensure_ascii=False,indent=2))

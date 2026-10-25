"""Assert that the local model can actually request a tool, not just produce prose."""
import json
from pathlib import Path
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def main():
    body = dict(model='qwen3:4b-instruct-2507-q4_K_M', stream=False, think=False, options={'num_ctx':4096,'temperature':0},
        messages=[{'role':'user','content':'Call the read_release tool for release_id shop-ready. Do not answer from memory.'}],
        tools=[{'type':'function','function':{'name':'read_release','description':'Read release evidence.',
            'parameters':{'type':'object','properties':{'release_id':{'type':'string'}},'required':['release_id']}}}])
    started = time.monotonic()
    req = urllib.request.Request('http://localhost:11434/api/chat',data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=180) as response:
        result=json.load(response)
    calls=result['message'].get('tool_calls',[])
    assert calls and calls[0]['function']['name']=='read_release', result
    assert calls[0]['function']['arguments']['release_id']=='shop-ready', result
    with urllib.request.urlopen('http://localhost:11434/api/ps') as response:
        running=json.load(response)
    record=dict(seconds=round(time.monotonic()-started,3),tool_calls=calls,running=running)
    (ROOT/'runtime').mkdir(exist_ok=True)
    (ROOT/'runtime'/'model-check.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(record,indent=2))


if __name__=='__main__':
    main()

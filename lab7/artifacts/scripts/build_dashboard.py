import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COUNT = 'n8n_workflow_execution_duration_seconds_count{workflow_id="lab8-release-readiness"}'
SUM = 'n8n_workflow_execution_duration_seconds_sum{workflow_id="lab8-release-readiness"}'
FAILED = 'n8n_workflow_execution_duration_seconds_count{workflow_id="lab8-release-readiness",status="failed"}'
rate = f'sum(rate({COUNT}[2m]))'
panels=[]
for i,(title,expression,unit,description) in enumerate([
    ('Частота выполнений', rate, 'ops', 'Все выполнения, включая отвергнутые запросы.'),
    ('Доля ошибочных выполнений', f'(sum(rate({FAILED}[2m])) or vector(0)) / clamp_min({rate}, 0.000001)', 'percentunit',
     'Failed в n8n: ошибки входа, зависимостей и обработки. Успешно обнаруженный blocked не является failed.'),
    ('Средняя длительность', f'sum(rate({SUM}[2m])) / clamp_min({rate}, 0.000001)', 's',
     'Средняя длительность всех завершённых выполнений за две минуты; короткие ошибки валидации снижают среднее.')]):
    panels.append(dict(id=i+1,type='timeseries',title=title,description=description,
        datasource={'type':'prometheus','uid':'lab8-prometheus'},gridPos={'h':8,'w':24,'x':0,'y':i*8},
        targets=[dict(refId='A',expr=expression,legendFormat=title)],
        fieldConfig={'defaults':{'unit':unit,'min':0},'overrides':[]},
        options={'legend':{'displayMode':'list','placement':'bottom'},'tooltip':{'mode':'single'}}))
dashboard=dict(uid='lab8-release',title='Lab8 — Release readiness',schemaVersion=39,version=1,
               refresh='5s',time={'from':'now-30m','to':'now'},timezone='browser',panels=panels)
assert len(panels)==3 and len({p['id'] for p in panels})==3
(ROOT/'monitoring/dashboard.json').write_text(json.dumps(dashboard,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('Generated three monitoring panels from built-in n8n execution metrics.')

"""Exercise the public webhook contract and retain measured results for the report."""
import argparse
import json
from pathlib import Path
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def invoke(body):
    started = time.monotonic()
    req = urllib.request.Request('http://localhost:5678/webhook/release-readiness',
        data=body if isinstance(body,bytes) else json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
    try:
        response = urllib.request.urlopen(req, timeout=330)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, json.load(response), round(time.monotonic() - started, 3)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--invalid-only', action='store_true')
    args = parser.parse_args()
    cases = [('malformed-json', b'{', 400, 'invalid_request'),
             ('bad-path', {'release_id': '../secret'}, 400, 'invalid_request'),
             ('extra-field', {'release_id': 'shop-ready', 'path': '/etc/passwd'}, 400, 'invalid_request'),
             ('unknown', {'release_id': 'missing'}, 404, 'release_not_found')]
    if not args.invalid_only:
        cases += [(name, {'release_id': name}, 200, status) for name, status in
                  [('shop-ready', 'ready'), ('shop-blocked', 'blocked'), ('shop-incomplete', 'incomplete'), ('shop-ready', 'ready')]]
    results, paths = [], []
    for name, body, expected_code, expected_status in cases:
        code, data, elapsed = invoke(body)
        result = dict(scenario=name, code=code, seconds=elapsed, response=data)
        results.append(result)
        (ROOT/'runtime').mkdir(exist_ok=True)
        (ROOT/'runtime'/'smoke-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        assert code == expected_code, (name, code, data)
        assert data.get('status', data.get('error')) == expected_status, (name, data)
        if code == 200:
            assert set(data) == {'release_id', 'status', 'report_path', 'report'}
            path = ROOT/'reports'/Path(data['report_path']).name
            assert path.read_bytes().decode('utf-8') == data['report']
            assert path.name not in paths, 'Repeat execution overwrote an earlier report'
            paths.append(path.name)
        print(f'PASS {name}: HTTP {code}, {expected_status}, {elapsed}s', flush=True)


if __name__ == '__main__':
    main()

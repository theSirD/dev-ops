"""Create/login to the isolated lab instance; keep local credentials out of Git."""
import http.cookiejar
import json
from pathlib import Path
import secrets
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BASE = 'http://localhost:5678'


def connect():
    runtime = ROOT / 'runtime'
    runtime.mkdir(exist_ok=True)
    account_file = runtime / 'account.json'
    client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def request(path, data=None, method=None):
        raw = json.dumps(data).encode() if data is not None else None
        req = urllib.request.Request(BASE + path, data=raw, method=method,
                                     headers={'Content-Type': 'application/json'})
        with client.open(req, timeout=30) as response:
            return json.load(response)

    settings = request('/rest/settings')['data']
    if settings['userManagement']['showSetupOnFirstLoad']:
        account = dict(email='lab8@example.invalid', firstName='Lab', lastName='Engineer',
                       password=secrets.token_urlsafe(20) + 'aA1!')
        account_file.write_text(json.dumps(account, indent=2) + '\n', encoding='utf-8')
        request('/rest/owner/setup', account)
        print('Created local owner; credentials saved in ignored runtime/account.json.')
    elif not account_file.exists():
        raise RuntimeError('Existing n8n owner detected; refusing to replace credentials.')
    account = json.loads(account_file.read_text(encoding='utf-8'))
    request('/rest/login', dict(emailOrLdapLoginId=account['email'], password=account['password']))
    return request


if __name__ == '__main__':
    import sys
    request = connect()
    if len(sys.argv) > 1 and sys.argv[1] == 'publish':
        current = request('/rest/workflows/lab8-release-readiness')['data']
        result = request('/rest/workflows/lab8-release-readiness/activate', {'versionId': current['versionId']})
        assert result['data']['active']
        print('Workflow active: http://localhost:5678/workflow/lab8-release-readiness')
    else:
        print('Local n8n account is ready.')

"""Build a tiny deterministic Git repository and three CI evidence scenarios."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT / 'fixtures' / 'repository'


def git(*args):
    env = {**os.environ, 'GIT_AUTHOR_DATE': '2026-10-22T09:00:00Z',
           'GIT_COMMITTER_DATE': '2026-10-22T09:00:00Z'}
    return subprocess.check_output(['git', '-c', f'safe.directory={REPO.as_posix()}', *args],
                                   cwd=REPO, env=env, text=True, encoding='utf-8').strip()


def main():
    REPO.mkdir(parents=True, exist_ok=True)
    if not (REPO / '.git').exists():
        if list(REPO.iterdir()):
            raise RuntimeError('Refusing to initialize a nonempty fixture directory.')
        git('init', '-b', 'main')
        git('config', 'user.name', 'Shop CI')
        git('config', 'user.email', 'ci@example.invalid')
        git('config', 'core.autocrlf', 'false')
        (REPO / 'shop.py').write_text('ORDER_TIMEOUT_SECONDS = 5\n', encoding='utf-8')
        git('add', 'shop.py')
        git('commit', '-m', 'Initial order timeout')
        (REPO / 'shop.py').write_text('ORDER_TIMEOUT_SECONDS = 10\n', encoding='utf-8')
        git('add', 'shop.py')
        git('commit', '-m', 'Increase order timeout to tolerate payment gateway latency')
    assert Path(git('rev-parse', '--show-toplevel')).resolve() == REPO.resolve()
    base, target = git('rev-parse', 'HEAD~1'), git('rev-parse', 'HEAD')
    assert len(base) == len(target) == 40 and base != target
    evidence_dir = ROOT / 'fixtures' / 'evidence'
    evidence_dir.mkdir(parents=True, exist_ok=True)
    (ROOT / 'reports').mkdir(exist_ok=True)
    catalog = {}
    for name, test_status in [('shop-ready', 'passed'), ('shop-blocked', 'failed'), ('shop-incomplete', 'unknown')]:
        release = dict(release_id=name, base_revision=base, target_revision=target,
                       evidence_path=f'/data/evidence/{name}.json')
        catalog[name] = release
        evidence = {key: release[key] for key in ['release_id', 'base_revision', 'target_revision']}
        evidence['checks'] = dict(tests=test_status, image_scan='passed', migration_review='passed')
        (evidence_dir / f'{name}.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
    (ROOT / 'fixtures' / 'catalog.json').write_text(json.dumps(catalog, indent=2) + '\n', encoding='utf-8')
    print(f'Fixtures ready: {base}..{target}; scenarios: {", ".join(catalog)}')


if __name__ == '__main__':
    main()

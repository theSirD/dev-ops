function validateRequest(body, catalog) {
  if (!body || Array.isArray(body) || typeof body !== 'object' || Object.keys(body).length !== 1 ||
      typeof body.release_id !== 'string' || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(body.release_id) || body.release_id.includes('\n')) {
    return { code: 400, error: 'invalid_request', message: 'Expected an object containing only a valid release_id.' };
  }
  if (!Object.hasOwn(catalog, body.release_id)) {
    return { code: 404, error: 'release_not_found', message: 'Unknown release identifier.' };
  }
  return { ...catalog[body.release_id], release_id: body.release_id };
}

function assessEvidence(evidence, release) {
  const blockers = [], unknown = [];
  for (const field of ['release_id', 'base_revision', 'target_revision']) {
    if (evidence?.[field] !== release[field]) unknown.push(`Evidence ${field} does not match the release catalog.`);
  }
  for (const name of ['tests', 'image_scan', 'migration_review']) {
    const value = evidence?.checks?.[name];
    if (value === 'failed') blockers.push(`${name}: failed`);
    else if (value !== 'passed') unknown.push(`${name}: ${value === 'unknown' ? 'unknown' : 'missing or invalid'}`);
  }
  return { status: blockers.length ? 'blocked' : unknown.length ? 'incomplete' : 'ready', blockers, unknown };
}

function parseAnalysis(output) {
  const text = output.trim().replace(/^```(?:json)?\s*/, '').replace(/\s*```$/, '');
  const data = JSON.parse(text);
  for (const field of ['changes', 'risks', 'unknown', 'sources']) {
    if (!Array.isArray(data[field]) || !data[field].every(x => typeof x === 'string' && x.trim())) {
      throw new Error(`Invalid analysis field: ${field}`);
    }
  }
  if (!data.changes.length || !data.sources.length) throw new Error('Analysis needs changes and sources.');
  return data;
}

function renderReport(release, assessment, analysis) {
  const list = values => values.length ? values.map(x => `- ${x}`).join('\n') : '- Нет.';
  return `## Релиз\n${release.release_id}\n\n## Статус\n${assessment.status}\n\n## Изменения\n${list(analysis.changes)}\n\nРиски изменений:\n${list(analysis.risks)}\n\n## Блокеры\n${list(assessment.blockers)}\n\n## Неизвестное\n${list([...assessment.unknown, ...analysis.unknown])}\n\n## Источники\n${list([`Git: ${release.base_revision}..${release.target_revision}`, `Evidence: ${release.evidence_path}`, ...analysis.sources])}\n`;
}

function verifyHead(text, expected) {
  if (typeof text !== 'string' || text.match(/^commit ([0-9a-f]{40})(?:\r?\n|$)/)?.[1] !== expected) {
    throw new Error('HEAD does not match release target.');
  }
}

function verifyToolEvidence(steps, release) {
  for (const required of ['git_diff', 'read_text_file']) {
    const verified = steps.some(step => {
      const name = step.action?.tool || '';
      const input = step.action?.toolInput || {};
      if (name !== required && !name.endsWith('_' + required)) return false;
      let observation;
      try { observation = JSON.parse(step.observation); } catch { return false; }
      if (!observation || observation.isError || observation.error) return false;
      if (required === 'git_diff') {
        return input.repo_path === '/data/repository' && input.target === release.base_revision &&
          Array.isArray(observation) && observation.some(item => item.type === 'text' &&
            typeof item.text === 'string' && item.text.startsWith(`Diff with ${release.base_revision}:`));
      }
      return input.path === release.evidence_path && input.head === undefined && input.tail === undefined &&
        typeof observation.content === 'string' && observation.content.trim().length > 0;
    });
    if (!verified) {
      throw new Error('Required successful MCP evidence was not collected: ' + required);
    }
  }
}

module.exports = { validateRequest, assessEvidence, parseAnalysis, renderReport, verifyToolEvidence, verifyHead };

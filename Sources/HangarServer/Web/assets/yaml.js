// Writes a workflow file as `.hangar.yml` text (docs/hangar-yml.md). The input has the API's JSON shape of
// `WorkflowFile`: `{version, workflows: {name: {project | workspace, xcode, teamID, tools, actions, postActions}}}`,
// with `postActions` as `[{name, settings, requiresApproval}]` and `actions` as archives
// `{kind: 'archive', scheme, platform, export}` (no `kind` also means an archive) or tests
// `{kind: 'test', scheme, platform, destination?, testPlan?}`, and `start` as `{manual: {branches: 'any' | [...]}}`.
//
// This file has no imports and ends with a single `export` line, so the round-trip test can load it in JXA
// (`osascript -l JavaScript`) after stripping that line.

/** Defaults of the `testflight` post-action; settings equal to them are left out. */
const TESTFLIGHT_DEFAULTS = {
  'wait-for-processing': true,
  'processing-timeout-minutes': 60,
  groups: [],
  'what-to-test': true,
  'submit-for-external-review': false,
};

const TESTFLIGHT_ORDER = Object.keys(TESTFLIGHT_DEFAULTS);

// A plain scalar with any of these would mean something else in YAML (a map, a comment, a flow collection, an
// anchor, a tag...), so such strings are quoted.
const SPECIAL = /[:#{}[\],&*?|<>=!%@`'"\\]/;
// Plain words that YAML 1.1 reads as booleans or null.
const RESERVED = /^(?:true|false|yes|no|on|off|y|n|null|~)$/i;

/** True when `text` must be double-quoted to stay the same string when parsed. */
function needsQuotes(text) {
  return text === ''
    || /^[0-9]/.test(text)
    || SPECIAL.test(text)
    || RESERVED.test(text)
    || /^[-+.~]/.test(text) // -1, +1, .5, .inf, a list item
    || /^\s|\s$/.test(text)
    || /[\u0000-\u001f\u007f\u0085\u2028\u2029]/.test(text);
}

/** `text` as a YAML double-quoted scalar. */
function quoted(text) {
  const escaped = String(text).replace(/[\\"\u0000-\u001f\u007f\u0085\u2028\u2029]/g, (character) => {
    switch (character) {
      case '\\': return '\\\\';
      case '"': return '\\"';
      case '\n': return '\\n';
      case '\t': return '\\t';
      case '\r': return '\\r';
      default: return `\\u${character.charCodeAt(0).toString(16).padStart(4, '0')}`;
    }
  });
  return `"${escaped}"`;
}

/** A string scalar, quoted only when it has to be. */
function string(text) {
  const value = String(text);
  return needsQuotes(value) ? quoted(value) : value;
}

/** Like `string`, but quoted unless it is a run of ASCII letters, digits and `._/-` (as the Swift writer does):
 * for simulator names and test plans, which often have spaces and parentheses. */
function name(text) {
  const value = String(text);
  return /^[A-Za-z/][A-Za-z0-9._/-]*$/.test(value) && !RESERVED.test(value) ? value : quoted(value);
}

/** Any settings value: booleans and numbers stay bare, strings follow `string`, lists and maps are flow style. */
function value(item) {
  if (item === null || item === undefined) return 'null';
  if (typeof item === 'boolean' || typeof item === 'number') return String(item);
  if (Array.isArray(item)) return `[${item.map(value).join(', ')}]`;
  if (typeof item === 'object') {
    const entries = Object.keys(item).map((key) => `${string(key)}: ${value(item[key])}`);
    return entries.length ? `{ ${entries.join(', ')} }` : '{}';
  }
  return string(item);
}

function sameValue(a, b) {
  if (Array.isArray(a) || Array.isArray(b)) {
    return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((item, i) => sameValue(item, b[i]));
  }
  return a === b;
}

/** The settings lines to write for a post-action: non-default ones for `testflight`, all of them otherwise. */
function settingsEntries(spec) {
  const settings = spec.settings ?? {};
  let keys = Object.keys(settings);
  if (spec.name === 'testflight') {
    const rank = (key) => {
      const index = TESTFLIGHT_ORDER.indexOf(key);
      return index < 0 ? TESTFLIGHT_ORDER.length : index;
    };
    keys = keys
      .filter((key) => !(Object.hasOwn(TESTFLIGHT_DEFAULTS, key) && sameValue(settings[key], TESTFLIGHT_DEFAULTS[key])))
      .sort((a, b) => rank(a) - rank(b));
  }
  const entries = keys.map((key) => [key, settings[key]]);
  // The server refuses approvals at deploy in Phase 1, but a spec that has one keeps it.
  if (spec.requiresApproval) entries.push(['requires-approval', true]);
  return entries;
}

/** Archives in the flat form, tests as `test: { ... }` with only the fields they set. */
function actionLine(action) {
  const fields = [`scheme: ${string(action.scheme)}`, `platform: ${string(action.platform)}`];
  if (action.kind !== 'test') return `{ ${[...fields, `export: ${string(action.export)}`].join(', ')} }`;
  if (action.destination !== undefined && action.destination !== null) fields.push(`destination: ${name(action.destination)}`);
  if (action.testPlan !== undefined && action.testPlan !== null) fields.push(`test-plan: ${name(action.testPlan)}`);
  return `test: { ${fields.join(', ')} }`;
}

function workflowLines(name, workflow) {
  const lines = [`  ${string(name)}:`];
  if (workflow.workspace !== undefined && workflow.workspace !== null) {
    lines.push(`    workspace: ${string(workflow.workspace)}`);
  } else {
    lines.push(`    project: ${string(workflow.project ?? '')}`);
  }
  lines.push(`    xcode: ${quoted(workflow.xcode ?? '')}`);
  if (workflow.teamID !== undefined && workflow.teamID !== null) lines.push(`    team: ${quoted(workflow.teamID)}`);
  const tools = workflow.tools ?? [];
  if (tools.length) lines.push(`    tools: [${tools.map(string).join(', ')}]`);
  // Manual start's source branches: `any`, or names and patterns.
  if (workflow.start) {
    const branches = workflow.start.manual?.branches ?? 'any';
    const list = Array.isArray(branches) ? `[${branches.map(string).join(', ')}]` : 'any';
    lines.push(`    start: { manual: { branches: ${list} } }`);
  }
  lines.push('    actions:');
  for (const action of workflow.actions ?? []) lines.push(`      - ${actionLine(action)}`);
  const postActions = workflow.postActions ?? [];
  if (postActions.length) {
    lines.push('    post-actions:');
    for (const spec of postActions) {
      const entries = settingsEntries(spec);
      if (entries.length === 0) {
        lines.push(`      - ${string(spec.name)}`);
        continue;
      }
      lines.push(`      - ${string(spec.name)}:`);
      for (const [key, setting] of entries) lines.push(`          ${string(key)}: ${value(setting)}`);
    }
  }
  return lines;
}

/** The `.hangar.yml` text for `file`, ending with a newline. Workflows keep the order of `file.workflows`. */
function workflowToYAML(file) {
  const lines = [`version: ${file.version ?? 1}`, 'workflows:'];
  for (const name of Object.keys(file.workflows ?? {})) lines.push(...workflowLines(name, file.workflows[name]));
  return `${lines.join('\n')}\n`;
}

export { workflowToYAML };

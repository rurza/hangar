// Pure rules of the variables editors (no DOM), so JXA tests can run them: which names look like secrets, how a
// workflow restriction reads, and which restrictions name workflows the app does not have.

/** Parts of a name that make it a secret: SENTRY_AUTH_TOKEN, APIKEY, DB_PASSWORD. DSN is not one: it is public. */
const SECRET_WORDS = ['TOKEN', 'SECRET', 'KEY', 'PASSWORD', 'PASSWD', 'PWD', 'CREDENTIAL', 'CREDENTIALS', 'PRIVATE'];
/** Run-together compounds: APIKEY, ACCESSTOKEN, CLIENTSECRET. A bare suffix match would make MONKEY a secret. */
const COMPOUND_PREFIXES = ['API', 'ACCESS', 'AUTH', 'CLIENT', 'APP', 'BEARER', 'REFRESH', 'SESSION', 'SIGNING', 'MASTER', 'ADMIN', 'DB'];
const COMPOUND_SUFFIXES = ['TOKEN', 'SECRET', 'KEY', 'PASSWORD'];

/**
 * Whether `name` looks like it holds a secret: one of its `_`-separated parts is one of the words above, or one of
 * the compounds (APIKEY, ACCESSTOKEN). Case does not matter.
 */
function looksSecret(name) {
  const parts = String(name ?? '').toUpperCase().split('_').filter((part) => part !== '');
  return parts.some((part) => SECRET_WORDS.includes(part)
    || COMPOUND_PREFIXES.some((prefix) => COMPOUND_SUFFIXES.some((suffix) => part === prefix + suffix)));
}

/** "a", "a and b", "a, b and c". */
function listText(items) {
  if (items.length <= 1) return items.join('');
  return `${items.slice(0, -1).join(', ')} and ${items.at(-1)}`;
}

/** "All workflows", "Beta", "Beta and Release". */
function workflowsText(workflows) {
  return workflows?.length ? listText(workflows) : 'All workflows';
}

/**
 * The names in `workflows` that are not among `known` (the app's workflow names), in order. With `known` null (the
 * names could not be read) nothing is unknown: no warning is better than a wrong one.
 */
function unknownWorkflows(workflows, known) {
  if (!known) return [];
  return (workflows ?? []).filter((name) => !known.includes(name));
}

/** The warning for a restriction with unknown names, or null: what a person reads under the variable or link. */
function unknownWorkflowsText(workflows, known, { group = false } = {}) {
  const missing = unknownWorkflows(workflows, known);
  if (missing.length === 0) return null;
  const quoted = listText(missing.map((name) => `“${name}”`));
  const verb = missing.length === 1 ? 'is not a workflow' : 'are not workflows';
  if (missing.length === workflows.length) {
    return `${quoted} ${verb} of this app any more: no build gets ${group ? 'these variables' : 'this value'}.`;
  }
  return `${quoted} ${verb} of this app any more.`;
}

/**
 * Another app variable named `name` whose workflows share one with `workflows`, or null. `except` is the variable being
 * edited. An empty list means all workflows: one of those never overlaps a restricted one (the restricted one wins),
 * but two of them are the same variable.
 */
function overlapping(variables, name, workflows, except = null) {
  for (const other of variables) {
    if (other === except || other.name !== name) continue;
    const theirs = other.workflows ?? [];
    if (theirs.length === 0 && workflows.length === 0) return other;
    if (theirs.some((workflow) => workflows.includes(workflow))) return other;
  }
  return null;
}

/** Sorted, trimmed and without duplicates or empty names, as the server stores a restriction. */
function normalizedWorkflows(workflows) {
  return [...new Set((workflows ?? []).map((name) => name.trim()).filter((name) => name !== ''))].sort();
}

export { looksSecret, listText, workflowsText, unknownWorkflows, unknownWorkflowsText, overlapping, normalizedWorkflows };

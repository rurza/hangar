// What a workflow does, in plain words. Shared by the app page and the Deploy sheet so both say the same thing.
// Reads the server's `Workflow` JSON, not the editor's model. Whether a Mac can run it is the server's call
// (`deploy-check`), never judged here.

const PLATFORM_NAMES = { ios: 'iOS', macos: 'macOS', visionos: 'visionOS', tvos: 'tvOS', watchos: 'watchOS' };

function platformName(platform) {
  return PLATFORM_NAMES[platform] ?? platform ?? '?';
}

/** "a", "a and b", "a, b and c". */
function listText(items) {
  if (items.length <= 1) return items.join('');
  return `${items.slice(0, -1).join(', ')} and ${items.at(-1)}`;
}

/** Whether the action runs tests rather than archiving. */
function isTest(action) {
  return action?.kind === 'test';
}

function actionText(action) {
  return `${action?.scheme ?? '?'} (${platformName(action?.platform)})`;
}

/** The TestFlight post-action's settings, or null without one. */
function testFlight(workflow) {
  const spec = (workflow?.postActions ?? []).find((item) => item.name === 'testflight');
  return spec ? (spec.settings ?? {}) : null;
}

function groupsOf(settings) {
  return Array.isArray(settings?.groups) ? settings.groups.filter(Boolean) : [];
}

/**
 * The workflow as the steps a deploy runs, each a short sentence:
 * ["Archives Legilo (macOS) and LegiloMobile (iOS) with Xcode 27.2.", "Uploads both to TestFlight for Internal."].
 */
function workflowSteps(workflow) {
  const actions = workflow?.actions ?? [];
  const tests = actions.filter(isTest);
  const archives = actions.filter((action) => !isTest(action));
  const steps = [];
  const xcode = workflow?.xcode ? ` with Xcode ${workflow.xcode}` : '';
  if (tests.length) steps.push(`Tests ${listText(tests.map(actionText))}${archives.length ? '' : xcode}.`);
  if (archives.length) steps.push(`Archives ${listText(archives.map(actionText))}${xcode}.`);
  if (!actions.length) steps.push('Has no actions yet.');

  const flight = testFlight(workflow);
  const uploadable = archives.filter((action) => action.export !== 'developer-id');
  if (flight && uploadable.length) {
    const what = uploadable.length === 1 ? 'it' : uploadable.length === 2 ? 'both' : 'them';
    const groups = groupsOf(flight);
    const waits = flight['wait-for-processing'] ?? true;
    if (groups.length && waits) {
      steps.push(`Uploads ${what} to TestFlight for ${listText(groups)}.`);
    } else {
      steps.push(`Uploads ${what} to TestFlight, where App Store Connect users with access can install ${uploadable.length === 1 ? 'it' : 'them'}.`);
    }
    if (flight['submit-for-external-review'] && waits) steps.push(`Submits ${what} for external beta review.`);
  } else if (archives.length) {
    const developerID = archives.every((action) => action.export === 'developer-id');
    steps.push(developerID
      ? archives.every((action) => action.notarize === false)
        ? 'Exports a Developer ID app, not notarized, to download from the build page.'
        : 'Exports a notarized Developer ID app to download from the build page.'
      : 'Uploads nothing: the .ipa or .pkg is on the build page to download.');
  }
  for (const spec of workflow?.postActions ?? []) {
    if (spec.name !== 'testflight') steps.push(`Then runs ${spec.name}.`);
  }
  return steps;
}

/**
 * Whether branch `name` matches `pattern`, as HangarCore's RefPattern: no `*` means that exact name; `*` matches
 * within one path level (`release/*`), `**` across levels; the whole name must match.
 */
function branchMatches(pattern, name) {
  const source = String(pattern).split(/(\*\*|\*)/).map((part) => {
    if (part === '**') return '.*';
    if (part === '*') return '[^/]*';
    return part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }).join('');
  return new RegExp(`^${source}$`).test(String(name));
}

/** Whether a manual build of `workflow` may start from branch `name` (any branch without a list). */
function allowsBranch(workflow, name) {
  const patterns = sourceBranches(workflow);
  return patterns.length === 0 || patterns.some((pattern) => branchMatches(pattern, name));
}

/** The branch Deploy suggests: the first exact name (no `*`) of the workflow's branches, else null. */
function suggestedBranch(workflow) {
  return sourceBranches(workflow).find((name) => !name.includes('*')) ?? null;
}

/** The branches a manual build starts from, as a list of names and patterns; empty for any branch. */
function sourceBranches(workflow) {
  const branches = workflow?.start?.manual?.branches;
  return Array.isArray(branches) ? branches : [];
}

/**
 * One line for a list: "main · Archives Legilo (macOS) and LegiloMobile (iOS) · TestFlight: Internal", led by the
 * source branches when the workflow names them.
 */
function workflowSummary(workflow) {
  const actions = workflow?.actions ?? [];
  const parts = [];
  const branches = sourceBranches(workflow);
  if (branches.length) parts.push(branches.join(', '));
  const tests = actions.filter(isTest);
  const archives = actions.filter((action) => !isTest(action));
  if (tests.length) parts.push(`Tests ${listText(tests.map(actionText))}`);
  if (archives.length) parts.push(`Archives ${listText(archives.map(actionText))}`);
  if (!actions.length) parts.push('No actions');
  const flight = testFlight(workflow);
  if (flight && archives.some((action) => action.export !== 'developer-id')) {
    // Without waiting for processing the worker only uploads, so it adds the build to no group.
    const groups = (flight['wait-for-processing'] ?? true) ? groupsOf(flight) : [];
    parts.push(groups.length ? `TestFlight: ${listText(groups)}` : 'TestFlight');
  } else if (archives.length) {
    parts.push('Download only');
  }
  return parts.join(' · ');
}

export { allowsBranch, branchMatches, listText, platformName, sourceBranches, suggestedBranch, workflowSteps, workflowSummary };

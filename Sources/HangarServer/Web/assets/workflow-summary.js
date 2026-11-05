// What a workflow does, in plain words, and whether a machine can run it. Shared by the app page and the Deploy
// sheet so both say the same thing. Reads the server's `Workflow` JSON, not the editor's model.

const PLATFORM_NAMES = { ios: 'iOS', macos: 'macOS', visionos: 'visionOS', tvos: 'tvOS', watchos: 'watchOS' };
const ONLINE_WINDOW_MS = 90_000;

export function platformName(platform) {
  return PLATFORM_NAMES[platform] ?? platform ?? '?';
}

/** "a", "a and b", "a, b and c". */
export function listText(items) {
  if (items.length <= 1) return items.join('');
  return `${items.slice(0, -1).join(', ')} and ${items.at(-1)}`;
}

/** Whether the action runs tests rather than archiving (for workflows that have such actions). */
function isTest(action) {
  return action?.kind === 'test' || action?.type === 'test';
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
export function workflowSteps(workflow) {
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
    if (flight['submit-for-external-review'] && waits) steps.push('Submits it for external beta review.');
  } else if (archives.length) {
    const developerID = archives.every((action) => action.export === 'developer-id');
    steps.push(developerID
      ? 'Exports a Developer ID app to download from the build page.'
      : 'Uploads nothing: the .ipa or .pkg is on the build page to download.');
  }
  for (const spec of workflow?.postActions ?? []) {
    if (spec.name !== 'testflight') steps.push(`Then runs ${spec.name}.`);
  }
  return steps;
}

/** One line for a list: "Archives Legilo (macOS) and LegiloMobile (iOS) · TestFlight: Internal". */
export function workflowSummary(workflow) {
  const actions = workflow?.actions ?? [];
  const parts = [];
  const tests = actions.filter(isTest);
  const archives = actions.filter((action) => !isTest(action));
  if (tests.length) parts.push(`Tests ${listText(tests.map(actionText))}`);
  if (archives.length) parts.push(`Archives ${listText(archives.map(actionText))}`);
  if (!actions.length) parts.push('No actions');
  const flight = testFlight(workflow);
  if (flight && archives.some((action) => action.export !== 'developer-id')) {
    const groups = groupsOf(flight);
    parts.push(groups.length ? `TestFlight: ${listText(groups)}` : 'TestFlight');
  } else if (archives.length) {
    parts.push('Download only');
  }
  return parts.join(' · ');
}

// MARK: Machines

/** A machine is online when it was seen within the last 90 seconds (as the server counts it). */
export function machineOnline(machine, now = new Date()) {
  if (!machine?.lastSeenAt) return false;
  const seen = new Date(machine.lastSeenAt);
  return !Number.isNaN(seen.getTime()) && now - seen <= ONLINE_WINDOW_MS;
}

/** "27.2" matches "27.2" and "27.2.1", not "27.20" (the scheduler's rule). */
function xcodeMatches(requested, installed) {
  const wanted = String(requested).split('.');
  const have = String(installed).split('.');
  return wanted.length > 0 && wanted.length <= have.length && wanted.every((part, index) => part === have[index]);
}

/**
 * What keeps `machine` from running `workflow` for good, as the scheduler sees it: Xcode, tools and signing. Busy
 * and low disk pass with time, so they are not listed. An empty list means it can run the workflow once online.
 * A machine that never reported is unknown: it gets `['has not reported yet']`.
 */
export function machineProblems(machine, workflow) {
  const report = machine?.report;
  if (!report) return ['has not reported yet'];
  const problems = [];
  if (workflow?.xcode && !(report.xcodes ?? []).some((xcode) => xcodeMatches(workflow.xcode, xcode.version))) {
    problems.push(`no Xcode ${workflow.xcode}`);
  }
  for (const tool of workflow?.tools ?? []) {
    if (!Object.hasOwn(report.tools ?? {}, tool)) problems.push(`no ${tool}`);
  }
  if (report.canSignWithoutPrompt === false) problems.push('cannot sign without a prompt');
  return problems;
}

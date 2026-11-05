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
function workflowSummary(workflow) {
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

export { listText, platformName, workflowSteps, workflowSummary };

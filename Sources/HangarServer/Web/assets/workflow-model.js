// The workflow editor's form model and its conversion from and to the API's JSON shape of `Workflow` (`teamID`,
// `postActions: [{name, settings, requiresApproval}]`). A model is plain fields the form inputs write to.
//
// No imports and a single final `export` line, so the round-trip test can load this file in JXA after stripping
// that line.

const DEFAULT_TIMEOUT = 60;

let nextKey = 0;

const ACTION_KINDS = [['archive', 'Archive'], ['test', 'Test']];

/** A new action of `kind`. Actions keep every field of both kinds, so switching kinds back and forth loses nothing;
 * `toWorkflow` writes only the fields of the action's kind. */
function blankAction(kind = 'archive') {
  return { kind, scheme: '', platform: 'ios', export: 'app-store-connect', destination: '', testPlan: '' };
}

function setActionKind(action, kind) {
  action.kind = kind;
}

/** An action in the API's JSON shape: archives `{kind, scheme, platform, export}`, tests
 * `{kind, scheme, platform, destination?, testPlan?}`. An empty or "recommended" destination is left out, as is any
 * destination of a macOS test (it runs on the Mac). */
function actionToJSON(action) {
  const base = { kind: action.kind, scheme: action.scheme.trim(), platform: action.platform };
  if (action.kind !== 'test') return { ...base, kind: 'archive', export: action.export };
  const destination = (action.destination ?? '').trim();
  if (destination && destination.toLowerCase() !== 'recommended' && action.platform !== 'macos') {
    base.destination = destination;
  }
  const testPlan = (action.testPlan ?? '').trim();
  if (testPlan) base.testPlan = testPlan;
  return base;
}

function blankTestFlight() {
  return {
    waitForProcessing: true, timeout: String(DEFAULT_TIMEOUT), groups: [], whatToTest: true,
    submitForExternalReview: false, requiresApproval: false,
  };
}

function scratchWorkflow(name) {
  return {
    key: ++nextKey, name, kind: 'project', path: '', xcode: '', team: '', tools: [], branches: null, actions: [blankAction()],
    testflightOn: true, testflight: blankTestFlight(), testflightIndex: 0, otherPostActions: [],
  };
}

function fromWorkflow(name, workflow) {
  const specs = workflow.postActions ?? [];
  const index = specs.findIndex((spec) => spec.name === 'testflight');
  const spec = index >= 0 ? specs[index] : null;
  const settings = spec?.settings ?? {};
  return {
    key: ++nextKey,
    name,
    kind: workflow.workspace !== undefined && workflow.workspace !== null ? 'workspace' : 'project',
    path: workflow.workspace ?? workflow.project ?? '',
    xcode: workflow.xcode ?? '',
    team: workflow.teamID ?? '',
    tools: [...(workflow.tools ?? [])],
    // Manual start's source branches: null without `start` (any branch), 'any', or a list of names and patterns.
    branches: startBranches(workflow.start),
    actions: (workflow.actions ?? []).map((action) => {
      const kind = action.kind === 'test' ? 'test' : 'archive';
      return {
        ...blankAction(kind), ...action, kind,
        export: action.export ?? 'app-store-connect',
        destination: action.destination ?? '',
        testPlan: action.testPlan ?? '',
      };
    }),
    testflightOn: Boolean(spec),
    testflight: spec
      ? {
        waitForProcessing: settings['wait-for-processing'] ?? true,
        timeout: String(settings['processing-timeout-minutes'] ?? DEFAULT_TIMEOUT),
        groups: [...(settings.groups ?? [])],
        whatToTest: settings['what-to-test'] ?? true,
        submitForExternalReview: settings['submit-for-external-review'] ?? false,
        requiresApproval: Boolean(spec.requiresApproval),
      }
      : blankTestFlight(),
    // Post-actions run in order, so the TestFlight step goes back where it was; one turned on later goes last.
    testflightIndex: index >= 0 ? index : specs.length,
    // The other post-actions (a second testflight, say) are kept as they are.
    otherPostActions: specs.filter((_, i) => i !== index),
  };
}

function startBranches(start) {
  if (!start) return null;
  const branches = start.manual?.branches;
  return Array.isArray(branches) ? [...branches] : 'any';
}

/** The first exact branch name (no `*`) of the model's source branches, or null. */
function firstExactBranch(model) {
  return Array.isArray(model.branches) ? model.branches.find((name) => !name.includes('*')) ?? null : null;
}

function toWorkflow(model) {
  const workflow = { [model.kind]: model.path.trim(), xcode: model.xcode.trim() };
  const team = model.team.trim();
  if (team) workflow.teamID = team;
  workflow.tools = [...model.tools];
  if (model.branches !== null && model.branches !== undefined) {
    workflow.start = { manual: { branches: Array.isArray(model.branches) ? [...model.branches] : 'any' } };
  }
  workflow.actions = model.actions.map(actionToJSON);
  const postActions = [...model.otherPostActions];
  if (model.testflightOn) {
    const t = model.testflight;
    const timeoutText = t.timeout.trim();
    const spec = {
      name: 'testflight',
      settings: {
        'wait-for-processing': t.waitForProcessing,
        // An entry that is not a whole number goes through as text, so the server names the problem.
        'processing-timeout-minutes': /^\d+$/.test(timeoutText) ? Number(timeoutText) : timeoutText,
        groups: [...t.groups],
        'what-to-test': t.whatToTest,
        'submit-for-external-review': t.submitForExternalReview,
      },
      requiresApproval: t.requiresApproval,
    };
    postActions.splice(Math.min(model.testflightIndex ?? postActions.length, postActions.length), 0, spec);
  }
  workflow.postActions = postActions;
  return workflow;
}

/** Models for the workflows of a `WorkflowFile` (API JSON), sorted by name. */
function modelsFromFile(file) {
  const workflows = file?.workflows ?? {};
  return Object.keys(workflows).sort().map((name) => fromWorkflow(name, workflows[name]));
}

/** The `WorkflowFile` (API JSON) the models describe, in their order. */
function fileFromModels(models) {
  const workflows = {};
  for (const model of models) workflows[model.name.trim()] = toWorkflow(model);
  return { version: 1, workflows };
}

/** Problems the parser would not catch (it accepts empty strings) or that the form would hide (duplicate names). */
function problems(models) {
  const found = [];
  const names = new Set();
  if (models.length === 0) found.push('Add at least one workflow.');
  models.forEach((model, index) => {
    const name = model.name.trim();
    const label = name ? `Workflow “${name}”` : `Workflow ${index + 1}`;
    if (!name) found.push(`${label} needs a name.`);
    else if (names.has(name)) found.push(`There are two workflows named “${name}”.`);
    names.add(name);
    if (!model.path.trim()) found.push(`${label} needs a ${model.kind} path.`);
    if (!model.xcode.trim()) found.push(`${label} needs an Xcode version.`);
    if (model.actions.length === 0) found.push(`${label} needs at least one action.`);
    if (model.actions.some((action) => !action.scheme.trim())) found.push(`${label} has an action without a scheme.`);
    if (model.testflightOn && !/^[1-9]\d*$/.test(model.testflight.timeout.trim())) {
      found.push(`${label}: the processing timeout must be a whole number of minutes above 0.`);
    }
  });
  return found;
}

// MARK: Words
//
// The whole workflow in words (the title's summary, the wizard's review, Deploy) is workflow-summary.js's job; this
// file only says what each action and the TestFlight step do.

const PLATFORMS = [['ios', 'iOS'], ['macos', 'macOS'], ['visionos', 'visionOS'], ['tvos', 'tvOS'], ['watchos', 'watchOS']];
/** The simulator a test of the platform runs on when no destination is set. */
const SIMULATOR_DEVICES = { ios: 'iPhone', visionos: 'Apple Vision Pro', tvos: 'Apple TV', watchos: 'Apple Watch' };

function platformName(platform) {
  const found = PLATFORMS.find(([value]) => value === platform);
  return found ? found[1] : String(platform ?? '');
}

/** "Archive – iOS", "Test – macOS". */
function actionTitle(action) {
  return `${action.kind === 'test' ? 'Test' : 'Archive'} – ${platformName(action.platform)}`;
}

/** Where a test action runs: "this Mac", "iPhone 17 Pro" or "the newest iPhone simulator". */
function testDestinationText(action) {
  if (action.platform === 'macos') return 'this Mac';
  const destination = (action.destination ?? '').trim();
  if (destination && destination.toLowerCase() !== 'recommended') return `the ${destination} simulator`;
  return `the newest ${SIMULATOR_DEVICES[action.platform] ?? platformName(action.platform)} simulator`;
}

/** "A", "A and B", "A, B and C". */
function listText(items) {
  if (items.length <= 1) return items.join('');
  return `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`;
}

/** Unique values in order. */
function unique(items) {
  const seen = [];
  for (const item of items) if (!seen.includes(item)) seen.push(item);
  return seen;
}

function archives(model) {
  return model.actions.filter((action) => action.kind !== 'test');
}

function tests(model) {
  return model.actions.filter((action) => action.kind === 'test');
}

/** The groups a TestFlight step adds builds to, as words: "Internal", "Internal and QA", or none. */
function groupsText(groups) {
  return listText(groups.map((group) => group.trim()).filter(Boolean));
}

// Sentences are lists of pieces: plain strings, and `{ strong: text }` for names the UI shows in bold.
const strong = (text) => ({ strong: text });

/** What an archive action does, e.g. "Archives LegiloMobile for iOS, stamps the build number, signs it for the App
 * Store and TestFlight and keeps the .ipa as an artifact." */
function describeArchive(action, model) {
  const scheme = action.scheme.trim() || 'the scheme';
  const file = action.platform === 'ios' || action.platform === 'tvos' || action.platform === 'visionos' || action.platform === 'watchos'
    ? '.ipa' : action.export === 'developer-id' ? '.app' : '.pkg';
  const signing = action.export === 'developer-id'
    ? 'signs it with Developer ID for download outside the App Store'
    : 'signs it for the App Store and TestFlight';
  const pieces = ['Archives ', strong(scheme), ' for ', strong(platformName(action.platform)),
    `, stamps the build number, ${signing} and keeps the ${file} as an artifact.`];
  if (model?.testflightOn && action.export !== 'developer-id') {
    // Without waiting for processing the worker only uploads: no groups, as describeTestFlight says.
    const groups = model.testflight.waitForProcessing ? groupsText(model.testflight.groups) : '';
    pieces.push(groups ? ` Then it goes to TestFlight for ${groups}.` : ' Then it goes to TestFlight.');
  }
  return pieces;
}

/** What a test action does. */
function describeTest(action) {
  const scheme = action.scheme.trim() || 'the scheme';
  const plan = (action.testPlan ?? '').trim();
  return ['Builds ', strong(scheme), ` and runs ${plan ? `its ${plan} test plan` : 'its tests'} on ${testDestinationText(action)}. `,
    'Failures fail this build; results appear on the build page.'];
}

/** What the TestFlight step does. */
function describeTestFlight(model) {
  const platforms = unique(archives(model).filter((action) => action.export !== 'developer-id')
    .map((action) => platformName(action.platform)));
  const groups = groupsText(model.testflight.groups);
  if (!platforms.length) return ['Has nothing to upload: no archive of this workflow is signed for the App Store.'];
  const after = `After each archive for ${listText(platforms)}, uploads`;
  if (!model.testflight.waitForProcessing) {
    return [`${after} the build to TestFlight and stops there: App Store Connect processes it on its own.`];
  }
  return [`${after} the build to TestFlight`, groups ? [' and adds it to ', strong(groups), '.'] : '. Only App Store Connect users with access see it.'].flat();
}

/** A sentence's pieces as plain text. */
function plainText(pieces) {
  return pieces.map((piece) => (typeof piece === 'string' ? piece : piece.strong)).join('');
}

// MARK: Validation per item

/**
 * What blocks a save, by sidebar item: `{ general, environment, actions: [[...] per action], testflight, workflow }`,
 * each a list of sentences. `context.workflowNames` are the other workflows' names; `context.betaGroups`, when
 * known, the app's TestFlight group names.
 */
function itemProblems(model, context = {}) {
  const result = { general: [], environment: [], start: [], actions: model.actions.map(() => []), testflight: [], workflow: [] };
  const name = model.name.trim();
  if (!name) result.general.push('Name the workflow.');
  else if ((context.workflowNames ?? []).includes(name)) result.general.push(`Another workflow is named “${name}”.`);
  if (!model.path.trim()) result.general.push(`Choose the ${model.kind === 'workspace' ? 'workspace' : 'project'} to build.`);
  if (!model.xcode.trim()) result.environment.push('Choose an Xcode version.');
  result.start = Array.isArray(model.branches) && model.branches.length === 0 ? ['Add a branch, or choose Any Branch.'] : [];
  if (model.actions.length === 0) result.workflow.push('Add an action: an archive or a test.');
  model.actions.forEach((action, index) => {
    const list = result.actions[index];
    if (!action.scheme.trim()) list.push('Choose a scheme.');
    if (action.kind !== 'test' && action.export === 'developer-id') {
      if (action.platform !== 'macos') list.push('Developer ID signs Mac apps only.');
      else if (model.testflightOn) list.push('TestFlight uploads every archive, and a Developer ID archive can’t go to TestFlight.');
    }
  });
  if (model.testflightOn) {
    if (archives(model).length === 0) result.testflight.push('TestFlight needs an archive action to upload.');
    if (!/^[1-9]\d*$/.test(model.testflight.timeout.trim())) result.testflight.push('The timeout is a whole number of minutes.');
    if (context.betaGroups && model.testflight.waitForProcessing) {
      const missing = model.testflight.groups.filter((group) => !context.betaGroups.includes(group));
      if (missing.length) {
        result.testflight.push(`App Store Connect has no group named ${listText(missing.map((group) => `“${group}”`))}.`);
      }
    }
  }
  return result;
}

/** Every sentence of `itemProblems`, in sidebar order. */
function allProblems(found) {
  return [...found.workflow, ...found.general, ...found.environment, ...found.start, ...found.actions.flat(), ...found.testflight];
}

// MARK: Detected schemes
//
// The detector leaves a scheme's platform out (`platform: null`) when it couldn't tell. Such a scheme is offered under
// every platform, marked `unverified`, so a platform it may build for is never greyed out.

/** Detected schemes for `platform`: those that build for it, then those of unknown platform (`unverified: true`); for
 * archives, apps first within each. */
function schemesFor(schemes, platform, kind) {
  const order = (list) => (kind === 'test' ? list : [...list.filter((s) => s.isApplication), ...list.filter((s) => !s.isApplication)]);
  const verified = (schemes ?? []).filter((scheme) => scheme.platform === platform);
  const unverified = (schemes ?? []).filter((scheme) => !scheme.platform).map((scheme) => ({ ...scheme, unverified: true }));
  return [...order(verified), ...order(unverified)];
}

/** Whether `platform` has a scheme to offer. Before detection (no schemes) every platform does. */
function platformHasSchemes(schemes, platform) {
  return !schemes?.length || schemesFor(schemes, platform, 'archive').length > 0;
}

/** The scheme a new action of `kind` for `platform` starts with: a verified one if any. Tests prefer an app with tests. */
function firstScheme(schemes, platform, kind) {
  const all = schemesFor(schemes, platform, kind);
  const verified = all.filter((scheme) => !scheme.unverified);
  const list = verified.length ? verified : all;
  if (kind === 'test') return (list.find((scheme) => scheme.isApplication && scheme.hasTests) ?? list.find((s) => s.hasTests) ?? list[0])?.name;
  return list.find((scheme) => scheme.isApplication)?.name ?? list[0]?.name;
}

/**
 * The detector's notes (what it guessed), filed by the field each concerns: `{ project, xcode, tools, schemes,
 * platforms }`, each a list except `platforms`, which maps a scheme name to its note. Advice the editor already gives
 * another way (the export, TestFlight, the icon) is left out.
 */
function detectionNotes(notes) {
  const filed = { project: [], xcode: [], tools: [], schemes: [], platforms: {} };
  for (const note of notes ?? []) {
    const platform = /^Couldn['’]t tell which platform (.+) builds for/.exec(note);
    if (platform) filed.platforms[platform[1]] = note;
    else if (/^Exports for App Store Connect|^Turn on TestFlight upload|^The app icon /.test(note)) continue;
    else if (/Xcode \S+ is a placeholder/.test(note)) filed.xcode.push(note);
    else if (/ci_scripts\//.test(note)) filed.tools.push(note);
    else if (/scheme|targets|builds \d+ apps/i.test(note)) filed.schemes.push(note);
    else filed.project.push(note);
  }
  return filed;
}

// MARK: The new-workflow wizard

/**
 * A model from the wizard's answers. `base` is the suggested workflow (API JSON) for the project, Xcode, team and
 * tools; `choices` are `[{scheme, platform, archive, test}]`; `distribution` is `testflight`, `developer-id` or
 * `keep`; `groups` the TestFlight group names. Tests come first: they report quickest.
 */
function wizardModel({ name, base, choices, distribution, groups = [], branches = null }) {
  const model = fromWorkflow(name, { ...(base ?? {}), actions: [], postActions: [] });
  model.branches = branches === null ? null : Array.isArray(branches) ? [...branches] : 'any';
  for (const choice of choices) {
    if (!choice.test) continue;
    model.actions.push({ ...blankAction('test'), scheme: choice.scheme, platform: choice.platform });
  }
  for (const choice of choices) {
    if (!choice.archive) continue;
    const exportMethod = distribution === 'developer-id' && choice.platform === 'macos' ? 'developer-id' : 'app-store-connect';
    model.actions.push({ ...blankAction('archive'), scheme: choice.scheme, platform: choice.platform, export: exportMethod });
  }
  model.testflightOn = distribution === 'testflight' && archives(model).length > 0;
  model.testflight.groups = [...groups];
  return model;
}

/** A name not in `taken`: `preferred`, else "preferred 2", "preferred 3"... */
function uniqueName(preferred, taken) {
  if (!taken.includes(preferred)) return preferred;
  let n = 2;
  while (taken.includes(`${preferred} ${n}`)) n += 1;
  return `${preferred} ${n}`;
}

export { ACTION_KINDS, detectionNotes, firstExactBranch, firstScheme, PLATFORMS, actionTitle, allProblems, blankAction, describeArchive, describeTest, describeTestFlight, fileFromModels, itemProblems, modelsFromFile, plainText, platformHasSchemes, platformName, problems, schemesFor, scratchWorkflow, setActionKind, testDestinationText, toWorkflow, uniqueName, wizardModel };

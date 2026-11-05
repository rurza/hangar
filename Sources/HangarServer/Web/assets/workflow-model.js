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
    key: ++nextKey, name, kind: 'project', path: '', xcode: '', team: '', tools: [], actions: [blankAction()],
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

function toWorkflow(model) {
  const workflow = { [model.kind]: model.path.trim(), xcode: model.xcode.trim() };
  const team = model.team.trim();
  if (team) workflow.teamID = team;
  workflow.tools = [...model.tools];
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

export { ACTION_KINDS, blankAction, fileFromModels, modelsFromFile, problems, scratchWorkflow, setActionKind };

// The new-workflow wizard: three short steps, prefilled from what Hangar found in the repository. 1. What to
// build: each app scheme with Archive and Run Tests. 2. Where builds go: TestFlight (with its groups), Developer ID
// or nowhere. 3. Review: the steps each deploy runs (as Deploy shows them), and its name. Create Workflow saves it; the editor is for
// fine-tuning afterwards.

import { confirm, field, h, replaceChildren, sheet, spinner, svg } from '../ui.js';
import {
  detectionNotes, platformName, schemePlatforms, testDestinationText, toWorkflow, uniqueName, wizardModel,
} from '../workflow-model.js';
import { workflowSteps } from '../workflow-summary.js';
import { choiceCards, groupPicker, guessNotes, tile } from './workflow-parts.js';

const OTHER_ANY = '\u0000any';
const STEPS = [['build', 'What to Build'], ['distribute', 'Where Builds Go'], ['review', 'Review']];

/**
 * Opens the wizard. `loadSuggestion()` resolves to the `WorkflowSuggestion`; `groups` is a `betaGroupsStore`;
 * `takenNames` are the names of the app's other workflows. `onCreate(model)` saves the new workflow (a thrown
 * error is shown in the sheet). `onBlank()`, when detection fails, starts from an empty workflow instead.
 */
export function openWorkflowWizard({ app, loadSuggestion, groups, branches, takenNames = [], onCreate, onBlank }) {
  const state = {
    step: 'build',
    suggestion: null,
    error: null,
    choices: [], // [{scheme, platform, archive, test, isApplication, hasTests}]
    showAll: false,
    distribution: null, // testflight | developer-id | keep; chosen once the groups are known
    groups: [],
    groupsTouched: false,
    name: uniqueName('Default', takenNames),
    touched: false,
    sourceBranches: undefined, // manual start's branches: the default branch once known; 'any'; null when unknown
    changingBranch: false,
  };
  branches.load().then((known) => {
    if (state.sourceBranches === undefined) state.sourceBranches = known?.defaultBranch ? [known.defaultBranch] : null;
    if (state.step === 'review' && handle.element.isConnected) render();
  });
  const steps = h('ol', { class: 'wf-steps', 'aria-label': 'Steps' });
  const content = h('div', { class: 'wf-wizard-content wf-form' });
  const handle = sheet({
    title: 'New Workflow',
    body: h('div', { class: 'wf-wizard' }, steps, content),
    actions: [],
    beforeDismiss: () => (state.touched ? confirm({
      title: 'Discard This Workflow?',
      message: 'It has not been created yet.',
      confirmLabel: 'Discard',
      cancelLabel: 'Keep Editing',
      destructive: true,
    }) : true),
  });
  handle.element.classList.add('wf-wizard-sheet');
  // Cancel on every step, on the left; it asks first once something was chosen.
  const cancel = { label: 'Cancel', kind: 'cancel', onClick: async () => (state.touched ? confirm({
    title: 'Discard This Workflow?',
    message: 'It has not been created yet.',
    confirmLabel: 'Discard',
    cancelLabel: 'Keep Editing',
    destructive: true,
  }) : true) };
  groups.load().then(() => { if (state.step === 'distribute') render(); });

  function load() {
    state.error = null;
    render();
    loadSuggestion().then((suggestion) => {
      state.suggestion = suggestion;
      state.choices = initialChoices(suggestion, app.name);
    }, (error) => {
      if (error.code === 'aborted') return;
      state.error = error;
    }).then(() => {
      if (!handle.element.isConnected) return;
      render();
      // The sheet held focus while loading; hand it to the first choice.
      if (document.activeElement === handle.element) content.querySelector('input, button')?.focus();
    });
  }

  const archived = () => state.choices.filter((choice) => choice.archive);
  // What detection guessed, shown by the scheme, platform or fact it concerns.
  const notes = () => detectionNotes(state.suggestion?.notes);
  const chosen = () => state.choices.filter((choice) => choice.archive || choice.test);

  function go(step) {
    state.step = step;
    handle.setError(null);
    render();
    handle.element.querySelector('.sheet-body')?.scrollTo?.(0, 0);
  }

  function render() {
    const skipped = state.suggestion && archived().length === 0;
    const order = STEPS.map(([id]) => id);
    const current = order.indexOf(state.step);
    replaceChildren(steps, STEPS.map(([id, label], index) => {
      const isSkipped = id === 'distribute' && skipped;
      const done = index < current && !isSkipped;
      return h('li', {
        class: ['wf-step', id === state.step && 'wf-step-current', done && 'wf-step-done', isSkipped && 'wf-step-skipped'],
        'aria-current': id === state.step ? 'step' : null,
      },
      h('span', { class: 'wf-step-number', 'aria-hidden': 'true' },
        done ? svg('svg', { viewBox: '0 0 10 10' }, svg('path', { d: 'M1.5 5.25l2.25 2.25 4.75-5' })) : String(index + 1)),
      h('span', { class: 'wf-step-label' }, label, isSkipped ? ' (not needed)' : ''));
    }));
    if (state.step === 'build') renderBuild();
    else if (state.step === 'distribute') renderDistribute();
    else renderReview();
  }

  // MARK: 1. What to build

  function renderBuild() {
    if (state.error) {
      replaceChildren(content,
        h('p', { class: 'wf-note wf-note-warning', role: 'alert' }, `Hangar couldn’t read the repository. ${state.error.message}`));
      handle.setActions([
        cancel,
        ...(onBlank ? [{ label: 'Start Blank', kind: 'secondary', onClick: () => { onBlank(); } }] : []),
        { label: 'Try Again', kind: 'primary', onClick: () => { load(); return false; } },
      ]);
      return;
    }
    if (!state.suggestion) {
      replaceChildren(content, h('div', { class: 'wf-wizard-loading' },
        spinner('Reading the repository'), h('p', null, `Reading ${repositoryName(app)}…`)));
      handle.setActions([cancel]);
      return;
    }
    // This app's schemes first; other apps' and non-app schemes wait behind a disclosure.
    const mine = state.choices.filter((choice) => choice.group === 'app');
    const others = state.choices.filter((choice) => choice.group !== 'app');
    const shown = mine.length === 0 || state.showAll ? state.choices : mine;
    const warning = duplicateWarning();
    replaceChildren(content,
      h('p', { class: 'wf-wizard-intro' }, `What should each deploy do? Hangar found these in ${repositoryName(app)}.`),
      h('ul', { class: 'wf-targets' }, shown.map(targetRow)),
      guessNotes(notes().schemes),
      warning ? h('p', { class: 'wf-note wf-note-warning', role: 'status' }, warning) : null,
      mine.length && others.length && !state.showAll
        ? h('button', {
          type: 'button', class: 'wf-more',
          onClick: () => { state.showAll = true; render(); },
        }, `Show ${others.length} More from This Repository`)
        : null);
    const next = archived().length ? 'distribute' : 'review';
    handle.setActions([cancel, {
      label: 'Next', kind: 'primary', disabled: chosen().length === 0,
      onClick: () => { go(next); return false; },
    }]);
  }

  function targetRow(choice) {
    const update = () => {
      state.touched = true;
      render();
      content.querySelector(`[data-choice="${CSS.escape(choiceKey(choice))}"] input[data-kind="${lastKind}"]`)?.focus();
    };
    let lastKind = '';
    const pill = (kind, label, disabled) => {
      const input = h('input', {
        type: 'checkbox', checked: choice[kind], disabled, dataset: { kind },
        onChange: () => { choice[kind] = input.checked; lastKind = kind; update(); },
      });
      return h('label', { class: 'wf-pill' }, input, label);
    };
    const platform = choice.platform;
    const what = choice.group === 'other-app' ? 'Another app in this repository'
      : choice.group === 'not-app' ? 'Not an app: it can only run tests'
        : choice.alternative ? `Another ${platformName(platform)} scheme in this repository`
          : null;
    return h('li', { class: 'wf-target', dataset: { choice: choiceKey(choice) } },
      tile(platform, 'platform'),
      h('span', { class: 'wf-target-text' },
        h('span', { class: 'wf-target-title' }, `${choice.scheme} · ${platformName(platform)}`),
        what ? h('span', { class: 'wf-target-detail' }, what) : null,
        choice.guessed ? h('span', { class: 'wf-target-detail' }, `Platform not detected, so ${platformName(platform)} is a guess`) : null,
        notes().platforms[choice.scheme] ? h('span', { class: 'wf-target-detail' }, notes().platforms[choice.scheme]) : null),
      h('div', { class: 'wf-target-options', role: 'group', 'aria-label': `What to do with ${choice.scheme}` },
        pill('test', 'Run Tests', false),
        pill('archive', 'Archive', choice.group === 'not-app')),
      h('p', { class: ['wf-target-outcome', !(choice.archive || choice.test) && 'wf-off'] }, outcome(choice)));
  }

  /** Two archives for one platform upload two builds with the same number, so App Store Connect takes only one. */
  function duplicateWarning() {
    const byPlatform = new Map();
    for (const choice of archived()) byPlatform.set(choice.platform, [...(byPlatform.get(choice.platform) ?? []), choice.scheme]);
    const twice = [...byPlatform.entries()].find(([, schemes]) => schemes.length > 1);
    if (!twice) return null;
    return `${listOf(twice[1])} both archive for ${platformName(twice[0])}. Each deploy gives them the same build number, so App Store Connect accepts only one: archive one of them, or put the other in its own workflow.`;
  }

  function outcome(choice) {
    const where = testDestinationText({ platform: choice.platform, destination: '' });
    if (choice.test && choice.archive) return `Runs its tests on ${where}, then archives it.${choice.hasTests ? '' : ' No test target was found, so check it has tests.'}`;
    if (choice.test) return `Runs its tests on ${where}.${choice.hasTests ? '' : ' No test target was found, so check it has tests.'}`;
    if (choice.archive) return 'Archives it for distribution.';
    return 'Not built.';
  }

  // MARK: 2. Where builds go

  function renderDistribute() {
    const groupState = groups.state;
    const macOnly = archived().every((choice) => choice.platform === 'macos');
    // With the platform: Velum archives for iOS and macOS, and only "Velum (iOS)" is not a Mac app.
    const notMac = archived().filter((choice) => choice.platform !== 'macos')
      .map((choice) => `${choice.scheme} (${platformName(choice.platform)})`);
    if (state.distribution === null && groupState) {
      state.distribution = groupState.notConfigured ? 'keep' : 'testflight';
      // One internal group: it is the obvious recipient.
      const internal = groupState.groups?.filter((group) => group.isInternal) ?? [];
      if (!state.groupsTouched && internal.length === 1) state.groups = [internal[0].name];
    }
    if (state.distribution === 'developer-id' && !macOnly) state.distribution = groupState?.notConfigured ? 'keep' : 'testflight';
    const ascMissing = Boolean(groupState?.notConfigured);
    const files = unique(archived().map((choice) => (choice.platform === 'macos' ? '.pkg' : '.ipa')));
    const options = [
      {
        value: 'testflight',
        title: 'Send to Testers with TestFlight',
        detail: ascMissing
          ? 'Needs the App Store Connect key. Add it in Settings first.'
          : 'Each build goes to App Store Connect and to the people in the groups you pick. They install it with the TestFlight app.',
        disabled: ascMissing,
        extra: groupPicker({
          store: groups, selected: state.groups,
          onChange: () => { state.groupsTouched = true; state.touched = true; },
        }),
      },
      {
        value: 'developer-id',
        title: 'Share the Mac App Yourself',
        detail: macOnly
          ? 'Signs it with Developer ID: download it from the build page and hand it out, outside the App Store.'
          : `Mac apps only, and ${listOf(notMac)} ${notMac.length === 1 ? 'isn’t one' : 'aren’t'}.`,
        disabled: !macOnly,
      },
      {
        value: 'keep',
        title: 'Just Keep the Build',
        detail: `Nothing leaves Hangar: the ${files.join(' and ')} ${files.length === 1 ? 'waits' : 'wait'} on the build page for you to download.`,
      },
    ];
    replaceChildren(content,
      h('p', { class: 'wf-wizard-intro' }, `After each deploy, where should ${archived().length === 1 ? 'the build' : 'the builds'} go?`),
      groupState
        ? choiceCards({
          legend: 'Where builds go', value: state.distribution, options,
          onChange: (value) => { state.distribution = value; state.touched = true; render(); },
        })
        : h('p', { class: 'wf-status-line' }, spinner('Checking App Store Connect'), 'Checking App Store Connect…'));
    handle.setActions([
      cancel,
      { label: 'Back', kind: 'secondary', onClick: () => { go('build'); return false; } },
      { label: 'Next', kind: 'primary', disabled: !state.distribution, onClick: () => { go('review'); return false; } },
    ]);
  }

  // MARK: 3. Review

  /** Selected TestFlight groups that are external, so the build needs Beta App Review. */
  function externalSelected() {
    const known = groups.state?.groups ?? [];
    return state.groups.some((name) => known.some((group) => group.name === name && group.isInternal === false));
  }

  function model() {
    const base = firstWorkflow(state.suggestion);
    return wizardModel({
      name: state.name.trim(), base, choices: chosen(), distribution: archived().length ? state.distribution : 'keep',
      groups: state.distribution === 'testflight' ? state.groups : [],
      externalReview: state.distribution === 'testflight' && externalSelected(),
      branches: state.sourceBranches ?? null,
    });
  }

  function renderReview() {
    const draft = model();
    const nameInput = h('input', {
      class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', value: state.name,
      onInput: (event) => { state.name = event.target.value; nameInput.removeAttribute('aria-invalid'); },
    });
    // The source branch: the default branch, with Change for another one or any branch. Nothing else is asked.
    const known = branches.state;
    const branchValue = state.sourceBranches === undefined ? 'Loading…'
      : Array.isArray(state.sourceBranches) ? state.sourceBranches.join(', ') : 'Any branch';
    let branchControl;
    if (state.changingBranch && known) {
      const select = h('select', {
        class: 'select wf-branch-select', 'aria-label': 'Source branch',
        onChange: () => {
          state.sourceBranches = select.value === OTHER_ANY ? 'any' : [select.value];
          state.changingBranch = false;
          state.touched = true;
          render();
          content.querySelector('.wf-change')?.focus();
        },
      },
      h('option', { value: OTHER_ANY }, 'Any branch'),
      known.branches.map((name) => h('option', { value: name }, name === known.defaultBranch ? `${name} (default)` : name)));
      select.value = Array.isArray(state.sourceBranches) ? state.sourceBranches[0] : OTHER_ANY;
      branchControl = select;
      queueMicrotask(() => select.focus());
    } else {
      branchControl = h('span', { class: 'wf-fact-value' }, branchValue, known
        ? h('button', { type: 'button', class: 'link-button wf-change', onClick: () => { state.changingBranch = true; render(); } }, 'Change')
        : null);
    }
    const guessed = notes();
    const facts = [
      ['Source branch', branchControl],
      [draft.kind === 'workspace' ? 'Workspace' : 'Project', draft.path || '—', guessed.project],
      ['Xcode', draft.xcode || '—', guessed.xcode],
      ['Team', draft.team || 'From the project'],
      ...(draft.tools.length || guessed.tools.length ? [['Tools', draft.tools.join(', ') || 'None', guessed.tools]] : []),
    ];
    const deployFrom = Array.isArray(state.sourceBranches) ? state.sourceBranches[0] : known?.defaultBranch;
    replaceChildren(content,
      // The same steps the Deploy sheet and the app page show for this workflow.
      h('ul', { class: 'wf-explain wf-steps-list', 'aria-label': 'What each deploy does' },
        workflowSteps(toWorkflow(draft)).map((step) => h('li', null, step))),
      field({ label: 'Name', control: nameInput }),
      h('div', { class: 'wf-field' },
        h('dl', { class: 'wf-facts' }, facts.map(([label, value, guesses]) => h('div', { class: 'wf-fact' },
          h('dt', null, label), h('dd', null, value),
          guesses?.length ? h('dd', { class: 'wf-fact-guesses' }, guessNotes(guesses)) : null))),
        h('p', { class: 'wf-field-hint' }, `${deployFrom ? `Deploy starts from ${deployFrom}. ` : ''}Found in the repository; change these and more in the editor once the workflow exists.`)));
    const back = archived().length ? 'distribute' : 'build';
    handle.setActions([
      cancel,
      { label: 'Back', kind: 'secondary', onClick: () => { go(back); return false; } },
      {
        label: 'Create Workflow', kind: 'primary',
        onClick: async () => {
          const name = state.name.trim();
          if (!name || takenNames.includes(name)) {
            nameInput.setAttribute('aria-invalid', 'true');
            nameInput.focus();
            throw new Error(name ? `Another workflow is named “${name}”. Choose another name.` : 'Name the workflow.');
          }
          await onCreate(model());
          return true;
        },
      },
    ]);
  }

  load();
  return handle;
}

// MARK: Helpers

function repositoryName(app) {
  return app.repoURL.replace(/^https:\/\/github\.com\//i, '').replace(/\.git$/, '');
}

function firstWorkflow(suggestion) {
  const workflows = suggestion?.workflows?.workflows ?? {};
  return workflows[Object.keys(workflows)[0]] ?? {};
}

/** One row per platform a scheme builds for, so a multiplatform app can be archived for each. */
function choiceKey(choice) {
  return `${choice.scheme}\u001f${choice.platform ?? ''}`;
}

/** Each detected scheme as a choice: the suggested ones archived, and tested when they have tests. A scheme that
 * builds for several platforms is one choice per platform. */
function initialChoices(suggestion, appName) {
  const suggested = firstWorkflow(suggestion).actions ?? [];
  const mine = new Set(suggested.map((action) => action.scheme));
  const schemes = suggestion.schemes?.length
    ? suggestion.schemes
    : suggested.map((action) => ({ name: action.scheme, platform: action.platform, isApplication: true, hasTests: false }));
  const choices = schemes.flatMap((scheme) => {
    const action = suggested.find((item) => item.scheme === scheme.name);
    const listed = schemePlatforms(scheme);
    const platforms = listed.length ? listed : [scheme.platform ?? action?.platform ?? 'macos'];
    return platforms.map((platform) => ({
      scheme: scheme.name,
      platform,
      isApplication: scheme.isApplication,
      hasTests: Boolean(scheme.hasTests),
      // No platform found in the project: this one is a guess, and the row says so.
      guessed: listed.length === 0,
      // app: this app's; other-app: an app with another bundle ID; not-app: tests, a framework...
      group: !scheme.isApplication ? 'not-app' : mine.has(scheme.name) || mine.size === 0 ? 'app' : 'other-app',
      alternative: false,
      archive: false,
      test: false,
    }));
  });
  // One archive per platform by default: the scheme named like the app, else the shortest name. The others (a
  // "Beta" scheme, say) start off, since two archives for one platform would upload the same build number twice.
  const lower = (text) => text.toLowerCase();
  for (const platform of new Set(choices.map((choice) => choice.platform))) {
    const candidates = choices.filter((choice) => choice.group === 'app' && choice.platform === platform);
    if (!candidates.length) continue;
    const primary = candidates.find((choice) => lower(choice.scheme) === lower(appName ?? ''))
      ?? [...candidates].sort((a, b) => a.scheme.length - b.scheme.length || a.scheme.localeCompare(b.scheme))[0];
    for (const choice of candidates) {
      choice.alternative = choice !== primary;
      choice.archive = choice === primary;
      choice.test = choice === primary && choice.hasTests;
    }
  }
  const rank = { app: 0, 'other-app': 1, 'not-app': 2 };
  return choices.sort((a, b) => rank[a.group] - rank[b.group] || Number(a.alternative) - Number(b.alternative)
    || a.scheme.localeCompare(b.scheme));
}

function unique(items) {
  return items.filter((item, index) => items.indexOf(item) === index);
}

function listOf(items) {
  if (items.length <= 1) return items.join('');
  return `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`;
}

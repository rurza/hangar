// The new-workflow wizard: three short steps, prefilled from what Hangar found in the repository. 1. What to
// build: each app scheme with Archive and Run Tests. 2. Where builds go: TestFlight (with its groups), Developer ID
// or nowhere. 3. Review: the workflow in one sentence, and its name. Create Workflow saves it; the editor is for
// fine-tuning afterwards.

import { confirm, field, h, replaceChildren, sheet, spinner, svg } from '../ui.js';
import {
  describeWorkflow, platformName, testDestinationText, uniqueName, wizardModel,
} from '../workflow-model.js';
import { choiceCards, groupPicker, sentence, tile } from './workflow-parts.js';

const STEPS = [['build', 'What to Build'], ['distribute', 'Where Builds Go'], ['review', 'Review']];

/**
 * Opens the wizard. `loadSuggestion()` resolves to the `WorkflowSuggestion`; `groups` is a `betaGroupsStore`;
 * `takenNames` are the names of the app's other workflows. `onCreate(model)` saves the new workflow (a thrown
 * error is shown in the sheet). `onBlank()`, when detection fails, starts from an empty workflow instead.
 */
export function openWorkflowWizard({ app, loadSuggestion, groups, takenNames = [], onCreate, onBlank }) {
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
  };
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
      destructive: true,
    }) : true),
  });
  groups.load().then(() => { if (state.step === 'distribute') render(); });

  function load() {
    state.error = null;
    render();
    loadSuggestion().then((suggestion) => {
      state.suggestion = suggestion;
      state.choices = initialChoices(suggestion);
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
    const cancel = { label: 'Cancel', kind: 'cancel' };
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
    const primary = state.choices.filter((choice) => choice.isApplication);
    const others = state.choices.filter((choice) => !choice.isApplication);
    const shown = primary.length === 0 || state.showAll ? state.choices : primary;
    replaceChildren(content,
      h('p', { class: 'wf-wizard-intro' }, `Choose what each deploy builds from ${repositoryName(app)}.`),
      h('ul', { class: 'wf-targets' }, shown.map(targetRow)),
      primary.length && others.length && !state.showAll
        ? h('button', {
          type: 'button', class: 'wf-more',
          onClick: () => { state.showAll = true; render(); },
        }, `Show ${others.length} More ${others.length === 1 ? 'Scheme' : 'Schemes'}`)
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
      content.querySelector(`[data-scheme="${CSS.escape(choice.scheme)}"] input[data-kind="${lastKind}"]`)?.focus();
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
    const kind = choice.isApplication ? `${platformName(platform)} app` : platform ? `${platformName(platform)} scheme` : 'Scheme';
    return h('li', { class: 'wf-target', dataset: { scheme: choice.scheme } },
      tile(platform ?? 'macos', 'platform'),
      h('span', { class: 'wf-target-text' },
        h('span', { class: 'wf-target-title' }, choice.scheme),
        h('span', { class: 'wf-target-detail' }, choice.hasTests ? `${kind} · has tests` : kind)),
      h('div', { class: 'wf-target-options', role: 'group', 'aria-label': `What to do with ${choice.scheme}` },
        pill('archive', 'Archive', !choice.isApplication),
        pill('test', 'Run Tests', false)),
      h('p', { class: ['wf-target-outcome', !(choice.archive || choice.test) && 'wf-off'] }, outcome(choice)));
  }

  function outcome(choice) {
    const parts = [];
    if (choice.test) {
      const where = testDestinationText({ platform: choice.platform ?? 'macos', destination: '' });
      parts.push(`Runs its tests on ${where}${choice.hasTests ? '' : ' (no test target found, so check the scheme has tests)'}`);
    }
    if (choice.archive) parts.push(parts.length ? 'archives it, signed for distribution' : 'Archives it, signed for distribution');
    if (!parts.length) return choice.isApplication ? 'Not built.' : 'Not built. This scheme isn’t an app, so it can only run tests.';
    return `${parts.join(', and ')}.`;
  }

  // MARK: 2. Where builds go

  function renderDistribute() {
    const groupState = groups.state;
    const macOnly = archived().every((choice) => choice.platform === 'macos');
    const notMac = archived().filter((choice) => choice.platform !== 'macos').map((choice) => choice.scheme);
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
        title: 'TestFlight — Internal Testers',
        detail: ascMissing
          ? 'Needs the App Store Connect key. Add it in Settings first.'
          : 'Uploads each build to App Store Connect and adds it to the groups you pick.',
        disabled: ascMissing,
        extra: groupPicker({
          store: groups, selected: state.groups, internalOnly: true,
          onChange: () => { state.groupsTouched = true; state.touched = true; },
        }),
      },
      {
        value: 'developer-id',
        title: 'Developer ID (Outside the App Store)',
        detail: macOnly
          ? 'Signs the Mac app for direct download. It can’t go to TestFlight.'
          : `Mac apps only: ${listOf(notMac)} ${notMac.length === 1 ? 'is' : 'are'} not.`,
        disabled: !macOnly,
      },
      {
        value: 'keep',
        title: 'Just Keep the Build',
        detail: `Signs it for the App Store and keeps the ${files.join(' and ')} on the build page. Nothing is uploaded.`,
      },
    ];
    replaceChildren(content,
      h('p', { class: 'wf-wizard-intro' }, `Where the ${archived().length === 1 ? 'archive goes' : 'archives go'} after each deploy.`),
      groupState
        ? choiceCards({
          legend: 'Where builds go', value: state.distribution, options,
          onChange: (value) => { state.distribution = value; state.touched = true; render(); },
        })
        : h('p', { class: 'wf-status-line' }, spinner('Checking App Store Connect'), 'Checking App Store Connect…'));
    handle.setActions([
      { label: 'Back', kind: 'secondary', onClick: () => { go('build'); return false; } },
      { label: 'Next', kind: 'primary', disabled: !state.distribution, onClick: () => { go('review'); return false; } },
    ]);
  }

  // MARK: 3. Review

  function model() {
    const base = firstWorkflow(state.suggestion);
    return wizardModel({
      name: state.name.trim(), base, choices: chosen(), distribution: archived().length ? state.distribution : 'keep',
      groups: state.distribution === 'testflight' ? state.groups : [],
    });
  }

  function renderReview() {
    const draft = model();
    const nameInput = h('input', {
      class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', value: state.name,
      onInput: (event) => { state.name = event.target.value; nameInput.removeAttribute('aria-invalid'); },
    });
    const facts = [
      [draft.kind === 'workspace' ? 'Workspace' : 'Project', draft.path || '—'],
      ['Xcode', draft.xcode || '—'],
      ['Team', draft.team || 'From the project'],
      ...(draft.tools.length ? [['Tools', draft.tools.join(', ')]] : []),
    ];
    replaceChildren(content,
      h('p', { class: 'wf-explain' }, sentence(describeWorkflow(draft))),
      field({ label: 'Name', control: nameInput }),
      h('div', { class: 'wf-field' },
        h('dl', { class: 'wf-facts' }, facts.map(([label, value]) => h('div', { class: 'wf-fact' }, h('dt', null, label), h('dd', null, value)))),
        h('p', { class: 'wf-field-hint' }, 'Found in the repository. Change these and more in the editor once the workflow exists.')));
    const back = archived().length ? 'distribute' : 'build';
    handle.setActions([
      { label: 'Back', kind: 'secondary', onClick: () => { go(back); return false; } },
      {
        label: 'Create Workflow', kind: 'primary',
        onClick: async () => {
          const name = state.name.trim();
          if (!name || takenNames.includes(name)) {
            nameInput.setAttribute('aria-invalid', 'true');
            nameInput.focus();
            throw new Error(name ? `Another workflow is named “${name}”.` : 'Name the workflow.');
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

/** Each detected scheme as a choice: the suggested ones archived, and tested when they have tests. */
function initialChoices(suggestion) {
  const suggested = firstWorkflow(suggestion).actions ?? [];
  const byScheme = new Map(suggested.map((action) => [action.scheme, action]));
  const schemes = suggestion.schemes?.length
    ? suggestion.schemes
    : suggested.map((action) => ({ name: action.scheme, platform: action.platform, isApplication: true, hasTests: false }));
  const choices = schemes.map((scheme) => {
    const action = byScheme.get(scheme.name);
    return {
      scheme: scheme.name,
      platform: scheme.platform ?? action?.platform ?? null,
      isApplication: scheme.isApplication,
      hasTests: Boolean(scheme.hasTests),
      archive: Boolean(action) && scheme.isApplication,
      test: Boolean(action) && Boolean(scheme.hasTests),
    };
  });
  // Apps first, then by name.
  return choices.sort((a, b) => Number(b.isApplication) - Number(a.isApplication) || a.scheme.localeCompare(b.scheme));
}

function unique(items) {
  return items.filter((item, index) => items.indexOf(item) === index);
}

function listOf(items) {
  if (items.length <= 1) return items.join('');
  return `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`;
}

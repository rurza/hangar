// The workflow editor (`/apps/:app/workflow`): the app's workflow file stored in Hangar, edited as a form and
// shown as `.hangar.yml`. The server's parser is the authority: a save sends the YAML and the form is rebuilt
// from what the server parsed.

import { api, ApiError, seg } from '../api.js';
import { addLeaveGuard, navigate } from '../router.js';
import {
  button, card, confirm, copyText, emptyState, field, h, page, relativeTime, replaceChildren, section, selectContents,
  spinner, switchField, toast,
} from '../ui.js';
import { workflowToYAML } from '../yaml.js';
import {
  ACTION_KINDS, blankAction, fileFromModels, modelsFromFile, problems, scratchWorkflow, setActionKind,
} from '../workflow-model.js';

const PLATFORMS = [
  ['ios', 'iOS'], ['macos', 'macOS'], ['visionos', 'visionOS'], ['tvos', 'tvOS'], ['watchos', 'watchOS'],
];
const EXPORTS = [['app-store-connect', 'App Store Connect'], ['developer-id', 'Developer ID']];

// MARK: Page

/** The `/apps/:app/workflow` route. */
export async function workflowPage(params, context) {
  const { signal } = context;
  let app;
  try {
    app = await api.get(`/apps/${seg(params.app)}`, { signal });
  } catch (error) {
    if (error instanceof ApiError && error.code === 'app_not_found') {
      return page({ title: 'App Not Found' }, emptyState({
        title: `There is no app “${params.app}”`,
        message: 'It may have been removed.',
        action: h('a', { href: '/', 'data-link': true, class: 'button button-primary' }, 'Go to Apps'),
      }));
    }
    throw error;
  }
  const base = `/apps/${seg(app.slug)}`;

  let stored = null;
  try {
    stored = await api.get(`${base}/workflow-file`, { signal });
  } catch (error) {
    if (error.code !== 'workflow_file_not_found') throw error;
  }

  const suggestions = machineSuggestions(signal);
  const editor = workflowEditor({ app, base, stored, suggestions, context });

  const view = page({
    title: 'Workflow',
    subtitle: `How ${app.name} builds when you deploy.`,
    actions: editor.saveButton,
  }, editor.element, suggestions.lists);
  view.prepend(h('a', { href: `/apps/${seg(app.slug)}`, 'data-link': true, class: 'back-link' },
    h('span', { 'aria-hidden': 'true' }, '‹ '), app.name));
  return view;
}

/** Datalists of Xcode versions and tool names that machines report; filled once `/machines` answers. */
function machineSuggestions(signal) {
  const xcodes = h('datalist', { id: 'workflow-xcodes' });
  const tools = h('datalist', { id: 'workflow-tools' });
  api.get('/machines', { signal }).then((machines) => {
    const versions = new Set();
    const names = new Set();
    for (const machine of machines ?? []) {
      for (const xcode of machine.report?.xcodes ?? []) if (xcode.version) versions.add(xcode.version);
      for (const name of Object.keys(machine.report?.tools ?? {})) names.add(name);
    }
    const byVersion = (a, b) => b.localeCompare(a, 'en', { numeric: true });
    replaceChildren(xcodes, [...versions].sort(byVersion).map((version) => h('option', { value: version })));
    replaceChildren(tools, [...names].sort().map((name) => h('option', { value: name })));
  }, () => {
    // Suggestions are a convenience; without machines the fields are still plain text.
  });
  return { lists: h('div', { hidden: true }, xcodes, tools), xcodes: xcodes.id, tools: tools.id };
}

// MARK: Editor

function workflowEditor({ app, base, stored: initial, suggestions, context }) {
  let stored = initial; // the StoredWorkflowFile, null while the app has none
  let models = stored ? modelsFromFile(stored.workflows) : null; // null: nothing being edited
  let saved = models ? snapshot() : null; // the file as last loaded or saved; null for an unsaved new one
  let tab = 'form';
  let busy = false;
  let detectedNotes = []; // what workflow detection guessed, shown above the form until the workflow is saved
  // Whether the repository has a .hangar.yml at its default branch: undefined until asked, null when unknown.
  let repoFile;
  let autoDetect = context.query?.get('suggest') === '1';
  {
    // The server remembers the answer for a while, so this is not a GitHub call on every visit. Asked with a
    // stored workflow too: Remove says whether builds would still have a workflow.
    api.get(`${base}/workflow-source?repository=1`, { signal: context.signal }).then(
      (status) => { repoFile = status?.repositoryHasWorkflowFile ?? null; },
      (error) => { if (error.code !== 'aborted') repoFile = null; },
    ).then(() => {
      if (!element.isConnected) return;
      // While editing only the Remove card depends on it; a full render would take the focus from a field.
      if (models === null) render();
      else element.querySelector('.danger-card')?.replaceWith(removeCard());
    });
  }

  const element = h('div', { class: 'workflow-editor' });
  const banner = h('div', { class: 'workflow-banner', role: 'alert', hidden: true });
  const saveButton = button('Save', { kind: 'primary', onClick: save });
  const status = h('p', { class: 'workflow-status', 'aria-live': 'polite' });

  function snapshot() {
    return JSON.stringify(fileFromModels(models));
  }

  function isDirty() {
    return models !== null && (saved === null || snapshot() !== saved);
  }

  function changed() {
    saveButton.disabled = busy || !isDirty();
    status.textContent = models === null ? ''
      : isDirty() ? (stored ? 'Unsaved changes' : 'Not saved yet')
        : `Saved ${relativeTime(stored?.updatedAt)}`;
  }

  function showError(message) {
    banner.textContent = message ?? '';
    banner.hidden = !message;
    if (message) banner.scrollIntoView?.({ block: 'center', behavior: 'smooth' });
  }

  // MARK: Leaving with unsaved edits

  const onBeforeUnload = (event) => {
    if (!isDirty()) return;
    event.preventDefault();
    event.returnValue = '';
  };
  window.addEventListener('beforeunload', onBeforeUnload);
  const confirmDiscard = () => confirm({
    title: 'Discard Unsaved Changes?',
    message: 'Your edits to the workflow have not been saved.',
    confirmLabel: 'Discard',
    destructive: true,
  });
  // Back and Forward: the router asks before leaving and restores this page's URL when the user stays.
  const removeLeaveGuard = addLeaveGuard(() => !isDirty() || confirmDiscard());
  // The router does not ask before following links, so in-app links are caught before its own (bubbling) click
  // handler.
  const onLinkClick = async (event) => {
    if (!isDirty() || event.defaultPrevented || event.button !== 0) return;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const link = event.target.closest?.('a[data-link]');
    if (!link || link.target === '_blank') return;
    const url = new URL(link.href, location.href);
    if (url.origin !== location.origin || (url.pathname === location.pathname && url.search === location.search)) return;
    event.preventDefault();
    event.stopPropagation();
    if (!(await confirmDiscard())) return;
    models = null;
    navigate(url.pathname + url.search + url.hash);
  };
  document.addEventListener('click', onLinkClick, true);
  context.onCleanup(() => {
    window.removeEventListener('beforeunload', onBeforeUnload);
    document.removeEventListener('click', onLinkClick, true);
    removeLeaveGuard();
  });

  // MARK: Rendering

  function render() {
    if (models === null) {
      saveButton.hidden = true;
      replaceChildren(element, startView());
      changed();
      return;
    }
    saveButton.hidden = false;
    replaceChildren(element,
      banner,
      detectedNotes.length && !stored
        ? h('div', { class: 'workflow-notes', role: 'note' },
          h('p', { class: 'workflow-notes-title' }, 'Detected from the repository. Check these before saving:'),
          h('ul', null, detectedNotes.map((note) => h('li', null, note))))
        : null,
      h('div', { class: 'workflow-toolbar' }, tabs(), status),
      tab === 'form' ? formView() : yamlView(),
      stored ? section({ title: 'Remove' }, removeCard()) : null);
    changed();
  }

  function tabs() {
    const item = (id, label) => h('button', {
      type: 'button', class: 'segment', role: 'tab', 'aria-selected': String(tab === id), id: `workflow-tab-${id}`,
      'aria-controls': 'workflow-panel', tabindex: tab === id ? '0' : '-1',
      onClick: () => {
        if (tab === id) return;
        tab = id;
        render();
        element.querySelector(`#workflow-tab-${id}`)?.focus();
      },
      onKeydown: (event) => {
        if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
        event.preventDefault();
        tab = tab === 'form' ? 'yaml' : 'form';
        render();
        element.querySelector(`#workflow-tab-${tab}`)?.focus();
      },
    }, label);
    return h('div', { class: 'segmented', role: 'tablist', 'aria-label': 'View' }, item('form', 'Form'), item('yaml', 'YAML'));
  }

  // MARK: Start

  function startView() {
    if (repoFile === undefined) {
      return card({ class: 'workflow-start' },
        h('p', { class: 'workflow-detecting' }, spinner('Checking the repository'), ' Checking the repository…'));
    }
    const message = h('p', { class: 'inline-error-message', role: 'alert', hidden: true });
    const progress = h('p', { class: 'workflow-detecting', hidden: true });
    const repoName = app.repoURL.replace(/^https:\/\/github\.com\//i, '').replace(/\.git$/, '');
    // With a .hangar.yml in the repository, using it is the first choice; detection would replace it.
    const detectButton = button('Use Detected Settings', { kind: repoFile === true ? 'secondary' : 'primary' });
    const importButton = button(
      repoFile === true ? 'Use the Repository’s .hangar.yml' : 'Start from the Repository’s .hangar.yml',
      { kind: repoFile === true ? 'primary' : 'secondary' });
    const scratchButton = button('Start from Scratch', {
      onClick: () => begin([scratchWorkflow('testflight')]),
    });
    // Offered only when the repository has a .hangar.yml to start from.
    importButton.hidden = repoFile !== true;
    const all = [detectButton, importButton, scratchButton];
    async function attempt(work) {
      message.hidden = true;
      all.forEach((b) => { b.disabled = true; });
      try {
        await work();
      } catch (error) {
        if (error.code === 'aborted') return;
        message.textContent = error.message;
        message.hidden = false;
      } finally {
        progress.hidden = true;
        if (element.contains(detectButton)) all.forEach((b) => { b.disabled = false; });
      }
    }
    detectButton.addEventListener('click', () => attempt(async () => {
      replaceChildren(progress, spinner(`Reading ${repoName}`), ` Reading ${repoName}…`);
      progress.hidden = false;
      const bundleID = context.query?.get('bundleID');
      const query = bundleID ? `?bundleID=${encodeURIComponent(bundleID)}` : '';
      const suggestion = await api.get(`${base}/workflow-suggestion${query}`, { signal: context.signal });
      detectedNotes = [
        ...(suggestion.hasWorkflowFile
          ? ['The repository has its own .hangar.yml. Saving this workflow makes builds use it instead.'] : []),
        ...(suggestion.notes ?? []),
      ];
      begin(modelsFromFile(suggestion.workflows));
    }));
    importButton.addEventListener('click', () => attempt(async () => {
      // The repository's default branch.
      const response = await api.get(`${base}/workflows`, { signal: context.signal });
      begin(modelsFromFile(response.workflows));
      toast(`Imported .hangar.yml at ${String(response.commit ?? '').slice(0, 7)}`, 'success');
    }));
    // Coming from Add App: read the repository at once, unless it has its own .hangar.yml (or that is not known yet).
    if (autoDetect && repoFile !== undefined && repoFile !== true) {
      autoDetect = false;
      queueMicrotask(() => detectButton.click());
    }
    return card({ class: 'workflow-start' },
      emptyState({
        title: 'No Workflow in Hangar',
        message: repoFile === true
          ? `${app.name} builds with the .hangar.yml in its repository. Edit it here to define the workflow in Hangar instead.`
          : `Define how ${app.name} builds: Hangar can fill the workflow in from the Xcode project in its repository.`,
        action: h('div', { class: 'workflow-start-actions' },
          repoFile === true ? [importButton, detectButton] : [detectButton, importButton], scratchButton),
      }),
      progress,
      message);
  }

  function begin(list) {
    models = list;
    saved = null;
    tab = 'form';
    showError(null);
    render();
    element.querySelector('.workflow-card input')?.focus();
  }

  // MARK: YAML

  function yamlView() {
    const text = workflowToYAML(fileFromModels(models));
    const code = h('pre', { class: 'yaml-block', tabindex: '0', 'aria-label': '.hangar.yml' }, h('code', null, text));
    return h('div', { id: 'workflow-panel', role: 'tabpanel', 'aria-labelledby': 'workflow-tab-yaml', class: 'workflow-panel' },
      card({ class: 'yaml-card' },
        code,
        h('div', { class: 'card-actions' },
          button('Copy as .hangar.yml', { onClick: () => copy(text, code) }))),
      h('p', { class: 'section-footer' },
        'Read-only. Commit it as .hangar.yml at the repository root and remove the Hangar workflow to build from the repository instead.'));
  }

  async function copy(text, code) {
    if (await copyText(text)) {
      toast('Copied .hangar.yml', 'success');
      return;
    }
    selectContents(code);
    toast('The YAML is selected. Press ⌘C to copy it.', 'info');
  }

  // MARK: Form

  function formView() {
    const cards = models.map((model) => workflowCard(model));
    return h('div', { id: 'workflow-panel', role: 'tabpanel', 'aria-labelledby': 'workflow-tab-form', class: 'workflow-panel' },
      cards,
      h('div', { class: 'list workflow-add' },
        h('button', { type: 'button', class: 'add-row-button', onClick: addWorkflow },
          h('span', { class: 'add-row-plus', 'aria-hidden': 'true' }, '+'),
          'Add Workflow')));
  }

  function addWorkflow() {
    const taken = new Set(models.map((model) => model.name.trim()));
    let name = 'testflight';
    for (let n = 2; taken.has(name); n += 1) name = `workflow-${n}`;
    const model = scratchWorkflow(name);
    models.push(model);
    render();
    element.querySelector(`[data-workflow="${model.key}"] input`)?.focus();
  }

  function workflowCard(model) {
    const container = card({ class: 'workflow-card', dataset: { workflow: String(model.key) } });

    function rerender(focusSelector) {
      container.replaceWith(workflowCard(model));
      changed();
      if (focusSelector) element.querySelector(`[data-workflow="${model.key}"] ${focusSelector}`)?.focus();
    }

    const text = (key, attrs = {}) => h('input', {
      class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false',
      autocapitalize: 'off', autocorrect: 'off', value: model[key], placeholder: attrs.placeholder, list: attrs.list,
      onInput: (event) => {
        model[key] = event.target.value;
        changed();
      },
    });

    const nameInput = text('name', { placeholder: 'testflight' });
    const removeWorkflow = models.length > 1
      ? button('Remove', {
        kind: 'plain-destructive', 'aria-label': `Remove workflow ${model.name || ''}`.trim(),
        onClick: () => {
          models = models.filter((other) => other !== model);
          render();
        },
      })
      : null;

    // Project or workspace: a segmented control choosing the key, and the path.
    const kindControl = h('div', { class: 'segmented segmented-small', role: 'radiogroup', 'aria-labelledby': `kind-${model.key}` },
      ['project', 'workspace'].map((kind) => h('button', {
        type: 'button', class: 'segment', role: 'radio', 'aria-checked': String(model.kind === kind),
        onClick: () => {
          if (model.kind === kind) return;
          model.kind = kind;
          rerender(`[data-kind="${kind}"]`);
        },
        dataset: { kind },
      }, kind === 'project' ? 'Project' : 'Workspace')));
    const pathInput = text('path', {
      placeholder: model.kind === 'project' ? 'MyApp.xcodeproj' : 'MyApp.xcworkspace',
    });
    pathInput.setAttribute('aria-label', model.kind === 'project' ? 'Project path' : 'Workspace path');

    const xcodeInput = text('xcode', { placeholder: '27.2', list: suggestions.xcodes });
    xcodeInput.setAttribute('inputmode', 'decimal');
    const teamInput = text('team', { placeholder: 'Optional, e.g. YL78V8PY6H' });

    const tools = chipsEditor({
      label: 'Tools',
      items: model.tools,
      placeholder: 'brew',
      list: suggestions.tools,
      onChange: changed,
    });

    container.append(
      h('div', { class: 'workflow-card-header' },
        h('div', { class: 'workflow-name' }, field({ label: 'Workflow name', control: nameInput })),
        removeWorkflow),
      h('div', { class: 'form workflow-fields' },
        h('div', { class: 'field' },
          h('div', { class: 'field-label-row' },
            h('span', { class: 'field-label', id: `kind-${model.key}` }, 'Project or workspace')),
          h('div', { class: 'location-row' }, kindControl, pathInput),
          h('p', { class: 'field-hint' }, 'Relative to the repository root. Its folder holds ci_scripts/.')),
        h('div', { class: 'field-pair' },
          field({ label: 'Xcode version', hint: 'Matched as a prefix: 27 picks any installed 27.x.', control: xcodeInput }),
          field({ label: 'Team ID', hint: 'Optional.', control: teamInput })),
        tools.element),
      actionsEditor(model, rerender),
      postActionsEditor(model, rerender));
    return container;
  }

  function actionsEditor(model, rerender) {
    const rows = model.actions.map((action, index) => {
      const n = index + 1;
      const scheme = h('input', {
        class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
        value: action.scheme, placeholder: 'Scheme', 'aria-label': `Scheme of action ${n}`, dataset: { scheme: String(index) },
        onInput: (event) => {
          action.scheme = event.target.value;
          changed();
        },
      });
      const select = (key, options, label) => {
        const control = h('select', {
          class: 'select', 'aria-label': `${label} of action ${n}`,
          onChange: (event) => {
            action[key] = event.target.value;
            changed();
          },
        }, options.map(([value, text]) => h('option', { value }, text)));
        // A value the form does not offer (impossible after parsing) still shows.
        if (!options.some(([value]) => value === action[key])) control.append(h('option', { value: action[key] }, action[key]));
        control.value = action[key];
        return control;
      };
      const kind = select('kind', ACTION_KINDS, 'Kind');
      kind.dataset.kind = String(index);
      kind.addEventListener('change', () => {
        setActionKind(action, kind.value);
        rerender(`[data-kind="${index}"]`);
      });
      const destination = h('input', {
        class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
        value: action.destination ?? '', placeholder: action.platform === 'macos' ? 'This Mac' : 'Recommended',
        disabled: action.platform === 'macos',
        'aria-label': `Simulator of action ${n}`,
        onInput: (event) => {
          action.destination = event.target.value;
          changed();
        },
      });
      const platform = select('platform', PLATFORMS, 'Platform');
      platform.dataset.platform = String(index);
      // A macOS test runs on the Mac, so its simulator field turns off.
      platform.addEventListener('change', () => {
        if (action.kind === 'test') rerender(`[data-platform="${index}"]`);
      });
      return h('li', { class: 'action-row' },
        kind,
        scheme,
        platform,
        action.kind === 'test' ? destination : select('export', EXPORTS, 'Export'),
        button('Remove', {
          kind: 'plain-destructive', 'aria-label': `Remove action ${n}`,
          onClick: () => {
            model.actions.splice(index, 1);
            rerender(model.actions.length ? `[data-scheme="${Math.max(0, index - 1)}"]` : '.add-action');
          },
        }));
    });
    return h('div', { class: 'workflow-group' },
      h('h3', { class: 'workflow-group-title' }, 'Actions'),
      h('p', { class: 'field-hint' },
        'An archive action archives one scheme and exports it; a test action runs its tests on a simulator (or this Mac for macOS). Post-actions follow archives only.'),
      h('div', { class: 'action-head', 'aria-hidden': 'true' },
        h('span', null, 'Kind'), h('span', null, 'Scheme'), h('span', null, 'Platform'), h('span', null, 'Export or simulator'), h('span')),
      h('ul', { class: 'action-list' }, rows),
      h('button', {
        type: 'button', class: 'add-row-button add-action',
        onClick: () => {
          model.actions.push(blankAction());
          rerender(`[data-scheme="${model.actions.length - 1}"]`);
        },
      }, h('span', { class: 'add-row-plus', 'aria-hidden': 'true' }, '+'), 'Add Action'));
  }

  function postActionsEditor(model, rerender) {
    const t = model.testflight;
    const toggle = switchField({
      label: 'Upload to TestFlight',
      hint: 'After every action succeeds.',
      checked: model.testflightOn,
      onChange: (checked) => {
        model.testflightOn = checked;
        rerender('.testflight-toggle input');
      },
    });
    toggle.element.classList.add('testflight-toggle');

    let settings = null;
    if (model.testflightOn) {
      const timeout = h('input', {
        class: 'input', type: 'text', inputmode: 'numeric', autocomplete: 'off', value: t.timeout,
        onInput: (event) => {
          t.timeout = event.target.value;
          changed();
        },
      });
      const wait = switchField({
        label: 'Wait for processing',
        hint: 'Until App Store Connect has processed the build.',
        checked: t.waitForProcessing,
        onChange: (checked) => {
          t.waitForProcessing = checked;
          changed();
          timeoutField.hidden = !checked;
        },
      });
      const timeoutField = field({ label: 'Processing timeout (minutes)', control: timeout });
      timeoutField.hidden = !t.waitForProcessing;
      const groups = chipsEditor({ label: 'Beta groups', items: t.groups, placeholder: 'Internal', onChange: changed });
      const flag = (label, hint, key) => switchField({
        label, hint, checked: t[key],
        onChange: (checked) => {
          t[key] = checked;
          changed();
        },
      }).element;
      settings = h('div', { class: 'testflight-settings form' },
        h('div', { class: 'switch-group' }, wait.element),
        timeoutField,
        groups.element,
        h('div', { class: 'switch-group' },
          flag('What to Test', 'Set the “What to Test” text.', 'whatToTest'),
          flag('Submit for external review', 'Submit the build for external beta review.', 'submitForExternalReview')),
        t.requiresApproval
          ? h('p', { class: 'field-hint' }, 'This step waits for approval (requires-approval in the file).')
          : null);
    }

    return h('div', { class: 'workflow-group' },
      h('h3', { class: 'workflow-group-title' }, 'Post-actions'),
      h('div', { class: 'switch-group' }, toggle.element),
      settings,
      model.otherPostActions.length
        ? h('p', { class: 'field-hint' },
          `Also runs ${model.otherPostActions.map((spec) => spec.name).join(', ')} (kept as in the file).`)
        : null);
  }

  // MARK: Save and remove

  async function save() {
    const found = problems(models);
    if (found.length) {
      showError(found.join(' '));
      return;
    }
    busy = true;
    changed();
    try {
      const file = fileFromModels(models);
      stored = await api.put(`${base}/workflow-file`, { yaml: workflowToYAML(file) });
      models = modelsFromFile(stored.workflows);
      saved = snapshot();
      showError(null);
      busy = false;
      render();
      toast('Workflow saved', 'success');
    } catch (error) {
      busy = false;
      changed();
      if (error.code === 'aborted') return;
      showError(error.message);
    }
  }

  function removeCard() {
    return card({ class: 'danger-card' },
      h('p', { class: 'card-detail' }, repoFile === true
        ? 'Deploys use the .hangar.yml in the repository again. Copy the YAML first if you want to commit it.'
        : repoFile === false
          ? `Without this workflow ${app.name} can’t build: the repository has no .hangar.yml.`
          : 'Deploys then need a .hangar.yml in the repository. Copy the YAML first if you want to commit it.'),
      h('div', { class: 'card-actions' },
        button('Remove Hangar Workflow…', { kind: 'destructive', onClick: remove })));
  }

  async function remove() {
    const confirmed = await confirm({
      title: 'Remove the Hangar Workflow?',
      message: repoFile === true
        ? `${app.name} builds with the .hangar.yml in its repository again.`
        : repoFile === false
          ? `${app.name}’s repository has no .hangar.yml, so deploys fail until you set up a workflow again.`
          : `${app.name} builds with the .hangar.yml in its repository again. Builds fail if it has none.`,
      confirmLabel: repoFile === false ? 'Remove and Disable Builds' : 'Remove',
      destructive: true,
    });
    if (!confirmed) return;
    try {
      await api.del(`${base}/workflow-file`);
    } catch (error) {
      toast(error.message, 'error');
      return;
    }
    stored = null;
    models = null;
    saved = null;
    showError(null);
    render();
    toast('Removed the Hangar workflow', 'success');
  }

  render();
  return { element, saveButton };
}

// MARK: Pieces

let chipsCount = 0;

/**
 * A list of short names as removable chips with a text field to add more (Return or the Add button). Edits
 * `items` in place and calls `onChange()`.
 */
function chipsEditor({ label, items, placeholder, list, onChange }) {
  const id = `chips-${++chipsCount}`;
  const chips = h('ul', { class: 'chips chips-editable', 'aria-label': label });
  const input = h('input', {
    id, class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
    placeholder, list,
    onKeydown: (event) => {
      if (event.key === 'Enter' && !event.isComposing) {
        event.preventDefault();
        add();
      } else if (event.key === 'Backspace' && input.value === '' && items.length) {
        items.pop();
        draw();
        onChange();
      }
    },
  });

  function add() {
    const value = input.value.trim();
    if (!value) return;
    if (!items.includes(value)) items.push(value);
    input.value = '';
    draw();
    onChange();
  }

  function draw() {
    replaceChildren(chips, items.map((item, index) => h('li', { class: 'chip chip-removable' },
      h('span', null, item),
      h('button', {
        type: 'button', class: 'chip-remove', 'aria-label': `Remove ${item}`,
        onClick: () => {
          items.splice(index, 1);
          draw();
          onChange();
          input.focus();
        },
      }, '×'))));
    chips.hidden = items.length === 0;
  }

  draw();
  const element = h('div', { class: 'field' },
    h('div', { class: 'field-label-row' }, h('label', { class: 'field-label', for: id }, label)),
    h('div', { class: 'chip-input-row' },
      input,
      h('button', { type: 'button', class: 'button button-secondary button-small', onClick: add }, 'Add')),
    chips);
  return { element };
}

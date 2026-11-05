// The workflow editor (`/apps/:app/workflow`), modelled on Xcode Cloud's: a sidebar of General, Environment,
// Start Conditions, Actions and Post-Actions, and the selected item's detail beside it (pushed on narrow screens).
// A new workflow starts in the wizard (workflow-wizard.js). The server's parser is the authority: a save sends the
// YAML and the editor is rebuilt from what the server parsed.

import { api, ApiError, seg } from '../api.js';
import { addLeaveGuard, navigate } from '../router.js';
import {
  button, card, confirm, copyText, emptyState, h, page, plusIcon, relativeTime, replaceChildren, selectContents, sheet, switchField,
  toast,
} from '../ui.js';
import { workflowToYAML } from '../yaml.js';
import {
  PLATFORMS, actionTitle, allProblems, blankAction, describeArchive, describeTest, describeTestFlight, detectionNotes, fileFromModels,
  firstExactBranch, firstScheme, itemProblems, modelsFromFile, platformHasSchemes, platformName, schemesFor, scratchWorkflow,
  testDestinationText, toWorkflow, uniqueName,
} from '../workflow-model.js';
import { workflowSummary } from '../workflow-summary.js';
import {
  betaGroupsStore, branchesStore, checkRow, chevron, choiceCards, explain, glyph, groupPicker, guessNotes, plusGlyph, segmented,
  tile,
} from './workflow-parts.js';
import { openWorkflowWizard } from './workflow-wizard.js';
import { openDeploySheet } from './deploy.js';

const OTHER = '\u0000other';

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
  let stored = null;
  try {
    stored = await api.get(`/apps/${seg(app.slug)}/workflow-file`, { signal });
  } catch (error) {
    if (error.code !== 'workflow_file_not_found') throw error;
  }
  return workflowEditor({ app, stored, context });
}

// MARK: Editor

function workflowEditor({ app, stored: initial, context }) {
  const base = `/apps/${seg(app.slug)}`;
  let stored = initial; // the StoredWorkflowFile, null while the app has none
  let models = stored ? modelsFromFile(stored.workflows) : []; // every workflow of the file
  let saved = stored ? snapshot() : null; // the file as last loaded or saved
  let current = 0; // index of the workflow on screen
  let selection = { kind: 'general' }; // the sidebar item: general, environment, start, action (with index), testflight
  let view = 'list'; // narrow screens: the sidebar (list) or the selected item (detail)
  let busy = false;
  let banner = null; // { kind: 'error' | 'success' | 'info', text, items?, actions? }
  let repoFile; // whether the repository has a .hangar.yml: undefined until known, null when unknown
  let machines = null; // [Machine] once loaded
  let suggestion = null; // WorkflowSuggestion once loaded
  let suggestionPromise = null;
  const groups = betaGroupsStore(base);
  const branches = branchesStore(base);

  // MARK: Data

  function loadSuggestion() {
    if (!suggestionPromise) {
      const bundleID = context.query?.get('bundleID');
      const query = bundleID ? `?bundleID=${encodeURIComponent(bundleID)}` : '';
      suggestionPromise = api.get(`${base}/workflow-suggestion${query}`, { signal: context.signal }).then((result) => {
        suggestion = result;
        if (element.isConnected && models.length) renderEditor();
        return result;
      }, (error) => {
        suggestionPromise = null;
        throw error;
      });
    }
    return suggestionPromise;
  }

  api.get('/machines', { signal: context.signal }).then((list) => {
    machines = list ?? [];
    if (element.isConnected && models.length) renderEditor();
  }, () => { machines = []; });

  if (stored) {
    loadSuggestion().catch(() => {});
    groups.load().then(() => { if (element.isConnected && models.length) renderEditor(); });
  }
  // Whether the repository has its own .hangar.yml, asked even with a stored workflow (`repository=1`): the start
  // view offers it only when it exists, and Delete says what builds fall back to. The server remembers the answer
  // for a while, so this is not a GitHub call on every visit.
  api.get(`${base}/workflow-source?repository=1`, { signal: context.signal }).then(
    (status) => { repoFile = status?.repositoryHasWorkflowFile ?? null; },
    (error) => { if (error.code !== 'aborted') repoFile = null; },
  ).then(() => {
    if (!element.isConnected || models.length) return;
    renderStart();
    // Coming from Add App: straight into the wizard, unless the repository has its own .hangar.yml.
    if (context.query?.get('suggest') === '1' && repoFile !== true) openWizard();
  });

  // MARK: State

  function snapshot() {
    return snapshotOf(models);
  }

  /** `list` as a file, sorted by name, so the order of the models (a new workflow last) is no edit. */
  function snapshotOf(list) {
    return JSON.stringify(fileFromModels([...list].sort((a, b) => (a.name.trim() < b.name.trim() ? -1 : 1))));
  }

  /** Every name a new workflow can't take: the workflows on screen and those as last saved (one may be renamed). */
  function takenNames() {
    return unique([...models.map((other) => other.name.trim()), ...Object.keys(stored?.workflows?.workflows ?? {})]);
  }

  function isDirty() {
    return models.length > 0 && (saved === null || snapshot() !== saved);
  }

  const model = () => models[current];

  function problemsOf(index = current) {
    const target = models[index];
    return itemProblems(target, {
      workflowNames: models.filter((_, i) => i !== index).map((other) => other.name.trim()),
      betaGroups: groups.state?.groups?.map((group) => group.name),
    });
  }

  // MARK: Leaving with unsaved edits

  const onBeforeUnload = (event) => {
    if (!isDirty()) return;
    event.preventDefault();
    event.returnValue = '';
  };
  window.addEventListener('beforeunload', onBeforeUnload);
  const confirmDiscard = () => confirm({
    title: 'Discard Changes?',
    message: 'Your edits to the workflow have not been saved.',
    confirmLabel: 'Discard',
    cancelLabel: 'Keep Editing',
    destructive: true,
  });
  // Back and Forward: the router asks before leaving and restores this page's URL when the user stays.
  const removeLeaveGuard = addLeaveGuard(() => !isDirty() || confirmDiscard());
  // The router does not ask before following links, so in-app links are caught before its own (bubbling) handler.
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
    saved = snapshot();
    navigate(url.pathname + url.search + url.hash);
  };
  document.addEventListener('click', onLinkClick, true);
  let closeMenu = null;
  context.onCleanup(() => {
    window.removeEventListener('beforeunload', onBeforeUnload);
    document.removeEventListener('click', onLinkClick, true);
    removeLeaveGuard();
    closeMenu?.();
  });

  // MARK: Page chrome

  const backLink = h('a', { href: base, 'data-link': true, class: 'back-link' }, h('span', { 'aria-hidden': 'true' }, '‹ '), app.name);
  const headerActions = h('div', { class: 'wf-header-actions' });
  const element = page({ title: 'Workflow', subtitle: ' ', actions: headerActions });
  element.classList.add('wf-page');
  element.prepend(backLink);
  const titleNode = element.querySelector('.large-title');
  const subtitleNode = element.querySelector('.page-subtitle');
  const body = h('div', { class: 'wf-body' });
  element.append(body);

  function updateChrome() {
    if (!models.length) {
      titleNode.textContent = 'Workflow';
      subtitleNode.textContent = `How ${app.name} builds when you deploy.`;
      replaceChildren(headerActions);
      return;
    }
    titleNode.textContent = model().name.trim() || 'Untitled Workflow';
    // The same line the app page shows for this workflow.
    subtitleNode.textContent = workflowSummary(toWorkflow(model()));
    const switcher = models.length > 1
      ? h('select', {
        class: 'select wf-switcher', 'aria-label': 'Workflow',
        onChange: (event) => switchTo(Number(event.target.value)),
      }, models.map((other, index) => h('option', { value: String(index), selected: index === current }, other.name.trim() || 'Untitled')))
      : null;
    replaceChildren(headerActions, switcher,
      button('New Workflow…', { kind: 'secondary', onClick: () => openWizard() }));
  }

  function switchTo(index) {
    current = index;
    selection = { kind: 'general' };
    view = 'list';
    renderEditor();
  }

  // MARK: Start

  function renderStart() {
    updateChrome();
    const createButton = button('Create Workflow', { kind: 'primary', onClick: () => openWizard() });
    const importButton = repoFile === true
      ? button('Use the Repository’s .hangar.yml', { kind: 'secondary', onClick: importRepositoryFile })
      : null;
    replaceChildren(body, card({ class: 'wf-start-card' },
      h('div', { class: 'wf-start' },
        tile('archive'),
        h('h2', { class: 'wf-start-title' }, `Set Up How ${app.name} Builds`),
        h('p', { class: 'wf-start-message' }, repoFile === true
          ? `${app.name} builds with the .hangar.yml in its repository. Start from it, or create a workflow in Hangar.`
          : 'Pick what to build and test and where the builds go. Hangar fills it in from the repository.'),
        h('div', { class: 'wf-start-actions' }, createButton, importButton))));
  }

  async function importRepositoryFile(event) {
    const control = event.currentTarget;
    control.disabled = true;
    try {
      const response = await api.get(`${base}/workflows`, { signal: context.signal });
      models = modelsFromFile(response.workflows);
      saved = null;
      current = 0;
      selection = { kind: 'general' };
      banner = { kind: 'info', text: `Imported the .hangar.yml at ${String(response.commit ?? '').slice(0, 7)}. Review it, then Save.` };
      renderEditor();
    } catch (error) {
      if (error.code !== 'aborted') toast(error.message, 'error');
      control.disabled = false;
    }
  }

  // MARK: Wizard

  function openWizard() {
    openWorkflowWizard({
      app,
      loadSuggestion,
      groups,
      branches,
      takenNames: takenNames(),
      onBlank: () => {
        const name = uniqueName('Default', takenNames());
        models = [...models, scratchWorkflow(name)];
        current = models.length - 1;
        selection = { kind: 'general' };
        banner = { kind: 'info', text: 'A blank workflow: fill in each item, then Save.' };
        renderEditor();
      },
      // Only the new workflow is saved, beside the workflows as last saved. Unsaved edits to the others stay
      // unsaved, so they still pass Save's checks first and Cancel still reverts them.
      onCreate: async (created) => {
        const name = created.name.trim();
        if (takenNames().includes(name)) throw new Error(`Another workflow is named “${name}”. Choose another name.`);
        const file = stored?.workflows ?? { version: 1, workflows: {} };
        stored = await api.put(`${base}/workflow-file`, {
          yaml: workflowToYAML({ ...file, workflows: { ...file.workflows, [name]: toWorkflow(created) } }),
        });
        const fresh = modelsFromFile(stored.workflows);
        models = [...models, fresh.find((other) => other.name === name) ?? created];
        saved = snapshotOf(fresh);
        current = models.length - 1;
        selection = { kind: 'general' };
        view = 'list';
        banner = savedBanner(name, { created: true, othersUnsaved: isDirty() });
        renderEditor();
      },
    });
  }

  /** The next step once a workflow is saved: deploy it, or add a Mac first when there is none (review P1-2). */
  function savedBanner(name, { created = false, othersUnsaved = false } = {}) {
    const noMac = machines !== null && machines.length === 0;
    const what = `${created ? `“${name}” is created.` : `Saved “${name}”.`}${othersUnsaved ? ' Your other edits are not saved yet.' : ''}`;
    return {
      kind: 'success',
      text: noMac
        ? `${what} Add a Mac to run it${created ? '; meanwhile, fine-tune any step here' : ''}.`
        : `${what} Deploy it now${created ? ', or fine-tune any step here' : ''}.`,
      actions: noMac
        ? [h('a', { href: '/machines', 'data-link': true, class: 'button button-primary button-small' }, 'Add Mac…')]
        : [button('Deploy Now', { kind: 'primary', class: 'button button-primary button-small', onClick: () => openDeploySheet(app) })],
    };
  }

  // MARK: Editor

  const editor = h('div', { class: 'wf-editor' });
  const sidebar = h('nav', { class: 'wf-sidebar', 'aria-label': 'Workflow items' });
  const detail = card({ class: 'wf-detail', role: 'region', 'aria-live': 'off' });
  const bannerSlot = h('div', { class: 'wf-banner-slot' });
  // The save bar: Cancel on the left, Save on the right, as on iOS. Sticky at the top of the editor on wide screens
  // and above the tab bar on phones, so Save is always in reach.
  const status = h('button', {
    type: 'button', class: 'wf-savebar-status', 'aria-live': 'polite',
    onClick: () => { if (status.dataset.problems) showFirstProblem(); },
  });
  const saveButton = button('Save', { kind: 'primary', onClick: save, 'aria-describedby': 'wf-save-status' });
  status.id = 'wf-save-status';
  const cancelButton = button('Cancel', { kind: 'plain', class: 'button button-plain wf-cancel', onClick: cancelEdits });
  const savebar = h('div', { class: 'wf-savebar' },
    cancelButton,
    status,
    h('div', { class: 'wf-savebar-actions' }, saveButton));
  editor.append(sidebar, detail);

  function renderEditor({ focusDetail = false } = {}) {
    if (!models.length) {
      renderStart();
      return;
    }
    if (current >= models.length) current = models.length - 1;
    if (selection.kind === 'action' && !model().actions[selection.index]) selection = { kind: 'general' };
    if (selection.kind === 'testflight' && !model().testflightOn) selection = { kind: 'general' };
    editor.dataset.view = view;
    if (!body.contains(editor)) replaceChildren(body, savebar, bannerSlot, editor);
    renderBanner();
    renderSidebar();
    renderDetail();
    refresh();
    if (focusDetail) detail.querySelector('.wf-detail-title')?.focus({ preventScroll: true });
  }

  /** Everything that follows from the model without rebuilding the detail pane (and losing focus there). */
  function refresh() {
    updateChrome();
    renderSidebar();
    const found = models.flatMap((_, index) => allProblems(problemsOf(index)));
    const dirty = isDirty();
    // With problems Save stays off, and the status says why and jumps to the first one.
    saveButton.disabled = busy || !dirty || found.length > 0;
    cancelButton.disabled = busy || !dirty;
    status.classList.toggle('wf-has-problems', dirty && found.length > 0);
    status.disabled = !(dirty && found.length > 0);
    if (dirty && found.length) status.dataset.problems = 'true';
    else delete status.dataset.problems;
    status.textContent = busy ? 'Saving…'
      : dirty
        ? found.length ? `${found.length === 1 ? 'Fix 1 problem' : `Fix ${found.length} problems`} to save ›` : (saved === null ? 'Not saved yet' : 'Unsaved changes')
        : `Saved ${relativeTime(stored?.updatedAt)}`;
    // Unsaved changes show in the title and the browser tab too.
    titleNode.classList.toggle('wf-dirty', dirty);
    document.title = `${dirty ? '• ' : ''}${models.length ? model().name.trim() || 'Workflow' : 'Workflow'} – Hangar`;
  }

  function changed() {
    refresh();
    // The detail's own problems list follows the edits.
    const slot = detail.querySelector('.wf-detail-problems');
    if (slot) replaceChildren(slot, problemList(itemProblemsFor(selection)));
  }

  function renderBanner() {
    if (!banner) {
      replaceChildren(bannerSlot);
      return;
    }
    const dismiss = h('button', { type: 'button', class: 'button button-plain button-small', onClick: () => { banner = null; renderBanner(); } }, 'Dismiss');
    replaceChildren(bannerSlot, h('div', {
      class: ['wf-banner', banner.kind === 'error' && 'wf-banner-error', banner.kind === 'success' && 'wf-banner-success'],
      role: banner.kind === 'error' ? 'alert' : 'status',
    },
    h('div', { class: 'wf-banner-text' }, banner.text,
      banner.items?.length ? h('ul', null, banner.items.map((item) => h('li', null, item))) : null),
    h('div', { class: 'wf-banner-actions' }, banner.actions ?? [], banner.kind === 'error' ? null : dismiss)));
  }

  // MARK: Sidebar

  function renderSidebar() {
    // A redraw replaces the menu's trigger, so an open menu goes with it.
    closeMenu?.();
    const target = model();
    const found = problemsOf();
    const row = (item, { icon, tone, title, detail: text, problems = [] }) => {
      const selected = sameItem(item, selection);
      return h('li', null, h('button', {
        type: 'button', class: 'wf-row', 'aria-current': selected ? 'true' : null,
        'aria-label': problems.length ? `${title}, ${problems.length === 1 ? 'one problem' : `${problems.length} problems`}` : null,
        dataset: { item: itemKey(item) },
        onClick: () => select(item),
      },
      tile(icon, tone),
      h('span', { class: 'wf-row-text' },
        h('span', { class: 'wf-row-title' }, title),
        text ? h('span', { class: 'wf-row-detail' }, text) : null),
      problems.length ? h('span', { class: 'wf-row-problem', 'aria-hidden': 'true' }, '!') : null,
      chevron()));
    };
    const group = (title, rows, add, empty) => h('div', { class: 'wf-group' },
      title ? h('div', { class: 'wf-group-header' }, h('h2', { class: 'wf-group-title' }, title), add) : null,
      rows.length ? h('ul', { class: 'wf-rows' }, rows) : h('p', { class: 'wf-group-empty' }, empty));

    const actionRows = target.actions.map((action, index) => row({ kind: 'action', index }, {
      icon: action.kind === 'test' ? 'test' : 'archive',
      title: actionTitle(action),
      detail: action.scheme.trim() || 'No scheme',
      problems: found.actions[index],
    }));
    const postRows = target.testflightOn ? [row({ kind: 'testflight' }, {
      icon: 'testflight', title: 'TestFlight Internal Testing',
      detail: target.testflight.groups.length ? target.testflight.groups.join(', ') : 'No groups',
      problems: found.testflight,
    })] : [];
    const focused = sidebar.contains(document.activeElement) ? document.activeElement.dataset.item : null;
    replaceChildren(sidebar,
      group(null, [
        row({ kind: 'general' }, {
          icon: 'general', title: 'General', detail: target.path.trim() || 'No project', problems: found.general,
        }),
        row({ kind: 'environment' }, {
          icon: 'environment', title: 'Environment',
          detail: target.xcode.trim() ? `Xcode ${target.xcode.trim()}` : 'No Xcode version', problems: found.environment,
        }),
      ]),
      group('Start Conditions', [row({ kind: 'start' }, {
        icon: 'start', tone: 'start', title: 'Manual Start',
        detail: Array.isArray(target.branches) ? target.branches.join(', ') || 'No branch' : 'Any branch',
        problems: found.start,
      })]),
      group('Actions', actionRows, addMenu('Add Action', actionMenuItems()), found.workflow[0] ?? 'No actions'),
      group('Post-Actions', postRows, addMenu('Add Post-Action', postActionMenuItems()), 'None'));
    if (focused) sidebar.querySelector(`[data-item="${focused}"]`)?.focus();
  }

  function select(item) {
    selection = item;
    view = 'detail';
    editor.dataset.view = view;
    renderSidebar();
    renderDetail();
    if (matchMedia('(max-width: 899.98px)').matches) {
      window.scrollTo(0, 0);
      detail.querySelector('.wf-detail-title')?.focus({ preventScroll: true });
    }
  }

  function backToList() {
    view = 'list';
    editor.dataset.view = view;
    sidebar.querySelector(`[data-item="${itemKey(selection)}"]`)?.focus();
  }

  // MARK: Add menus

  function actionMenuItems() {
    const items = [];
    for (const kind of ['archive', 'test']) {
      items.push({ heading: kind === 'archive' ? 'Archive' : 'Test' });
      for (const [platform, label] of PLATFORMS) {
        const available = platformHasSchemes(suggestion?.schemes, platform);
        items.push({
          icon: kind, label, disabled: !available, detail: available ? null : `No scheme for ${label} in this repository`,
          onSelect: () => addAction(kind, platform),
        });
      }
    }
    return items;
  }

  function postActionMenuItems() {
    const target = model();
    const hasArchive = target.actions.some((action) => action.kind !== 'test');
    return [{
      icon: 'testflight', label: 'TestFlight Internal Testing',
      disabled: target.testflightOn || !hasArchive,
      detail: target.testflightOn ? 'Already added' : hasArchive ? null : 'Add an archive action first',
      onSelect: () => {
        target.testflightOn = true;
        select({ kind: 'testflight' });
        changed();
      },
    }];
  }

  function addAction(kind, platform) {
    const target = model();
    const action = { ...blankAction(kind), platform, scheme: firstScheme(suggestion?.schemes, platform, kind) ?? '' };
    target.actions.push(action);
    select({ kind: 'action', index: target.actions.length - 1 });
    changed();
  }

  /** The "+" button and its menu. `items`: `{heading}` or `{icon, label, detail, disabled, onSelect}`. */
  function addMenu(label, items) {
    const trigger = h('button', {
      type: 'button', class: 'wf-icon-button', 'aria-label': label, 'aria-haspopup': 'menu', 'aria-expanded': 'false',
    }, plusIcon());
    trigger.addEventListener('click', () => {
      if (closeMenu) {
        closeMenu();
        return;
      }
      open();
    });
    trigger.addEventListener('keydown', (event) => {
      if (event.key === 'ArrowDown') {
        event.preventDefault();
        open();
      }
    });
    function open() {
      const menu = h('div', { class: 'wf-menu', role: 'menu', 'aria-label': label });
      const buttons = [];
      for (const item of items) {
        if (item.heading) {
          if (buttons.length) menu.append(h('div', { class: 'wf-menu-separator', role: 'separator' }));
          menu.append(h('div', { class: 'wf-menu-heading', role: 'presentation' }, item.heading));
          continue;
        }
        const entry = h('button', {
          type: 'button', class: 'wf-menu-item', role: 'menuitem', tabindex: '-1',
          'aria-disabled': item.disabled ? 'true' : null,
          onClick: () => {
            if (item.disabled) return;
            close(false);
            item.onSelect();
          },
        }, glyph(item.icon), h('span', null, item.label), item.detail ? h('span', { class: 'wf-menu-item-detail' }, item.detail) : null);
        buttons.push(entry);
        menu.append(entry);
      }
      menu.addEventListener('keydown', (event) => {
        const index = buttons.indexOf(document.activeElement);
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
          event.preventDefault();
          const step = event.key === 'ArrowDown' ? 1 : -1;
          buttons[(index + step + buttons.length) % buttons.length].focus();
        } else if (event.key === 'Home' || event.key === 'End') {
          event.preventDefault();
          buttons[event.key === 'Home' ? 0 : buttons.length - 1].focus();
        } else if (event.key === 'Escape') {
          event.preventDefault();
          event.stopPropagation();
          close(true);
        } else if (event.key === 'Tab') {
          close(false);
        }
      });
      const outside = (event) => {
        if (!menu.contains(event.target) && event.target !== trigger && !trigger.contains(event.target)) close(false);
      };
      function close(refocus) {
        document.removeEventListener('pointerdown', outside, true);
        menu.remove();
        trigger.setAttribute('aria-expanded', 'false');
        closeMenu = null;
        if (refocus) trigger.focus();
      }
      closeMenu?.();
      closeMenu = () => close(false);
      trigger.after(menu);
      // Opens upwards when the room below (above the save bar) is short and there is more above.
      const box = menu.getBoundingClientRect();
      const below = innerHeight - 72 - trigger.getBoundingClientRect().bottom;
      if (box.bottom > innerHeight - 72 && trigger.getBoundingClientRect().top - 64 > below) menu.classList.add('wf-menu-up');
      trigger.setAttribute('aria-expanded', 'true');
      document.addEventListener('pointerdown', outside, true);
      (buttons.find((b) => !b.getAttribute('aria-disabled')) ?? buttons[0])?.focus();
    }
    return trigger;
  }

  // MARK: Detail

  function itemProblemsFor(item) {
    const found = problemsOf();
    if (item.kind === 'action') return found.actions[item.index] ?? [];
    if (item.kind === 'general') return [...found.workflow, ...found.general];
    return found[item.kind] ?? [];
  }

  function problemList(list) {
    return list.length
      ? h('div', { class: 'wf-banner wf-banner-error', role: 'alert' },
        h('div', { class: 'wf-banner-text' }, list.length === 1 ? list[0] : h('ul', null, list.map((item) => h('li', null, item)))))
      : null;
  }

  function renderDetail() {
    const target = model();
    let content;
    if (selection.kind === 'general') content = generalPane(target);
    else if (selection.kind === 'environment') content = environmentPane(target);
    else if (selection.kind === 'start') content = startPane(target);
    else if (selection.kind === 'testflight') content = testFlightPane(target);
    else content = actionPane(target, selection.index);
    replaceChildren(detail,
      h('button', { type: 'button', class: 'wf-back', onClick: backToList }, chevron('left'), 'Workflow'),
      content.header,
      h('div', { class: 'wf-detail-problems' }, problemList(itemProblemsFor(selection))),
      content.body);
  }

  function header({ icon, tone, title, subtitle, tools }) {
    return h('div', { class: 'wf-detail-header' },
      tile(icon, tone),
      h('div', { class: 'wf-detail-heading' },
        h('h2', { class: 'wf-detail-title', tabindex: '-1' }, title),
        subtitle ? h('p', { class: 'wf-detail-subtitle' }, subtitle) : null),
      tools ? h('div', { class: 'wf-detail-tools' }, tools) : null);
  }

  // MARK: General

  function generalPane(target) {
    const nameInput = textInput(target.name, (value) => { target.name = value; }, { invalid: () => !target.name.trim() });
    const projects = unique([...(suggestion?.projects ?? []), target.path.trim()].filter(Boolean));
    const project = pickerWithOther({
      label: 'Project or workspace',
      value: target.path.trim(),
      options: projects.map((path) => [path, path]),
      placeholder: 'MyApp.xcodeproj',
      hint: target.kind === 'workspace' ? 'A workspace, relative to the repository root.' : 'Relative to the repository root. Its folder holds ci_scripts/.',
      note: guessNotes(notes().project),
      onChange: (value) => {
        target.path = value;
        target.kind = /\.xcworkspace\/?$/i.test(value.trim()) ? 'workspace' : 'project';
      },
    });
    const repository = app.repoURL.replace(/\.git$/, '');
    const removeButton = button('Delete Workflow…', { kind: 'plain', class: 'button button-plain wf-destructive wf-flush-start', onClick: removeWorkflow });
    return {
      header: header({ icon: 'general', title: 'General', subtitle: 'What this workflow is called and what it builds.' }),
      body: h('div', { class: 'wf-form' },
        wfField({ label: 'Name', control: nameInput }),
        wfField({ label: 'Repository', control: h('div', { class: 'wf-readonly' }, h('a', { href: repository, target: '_blank', rel: 'noopener' }, repository.replace(/^https:\/\//, ''), ' ↗')) }),
        project,
        wfField({
          label: 'As a file',
          control: h('div', null, button('Show .hangar.yml', { kind: 'plain', class: 'button button-plain wf-flush-start', onClick: showYAML })),
          hint: 'The workflow as YAML, to commit to the repository if you like.',
        }),
        h('div', { class: 'wf-field wf-danger-zone' }, removeButton,
          models.length === 1 && stored
            ? h('p', { class: 'wf-field-hint' }, repoFile === true
              ? `Without it, ${app.name} builds with the .hangar.yml in its repository.`
              : repoFile === false
                ? `Without it, ${app.name} can’t build: the repository has no .hangar.yml.`
                : `Without it, ${app.name} needs a .hangar.yml in its repository to build.`)
            : null)),
    };
  }

  // MARK: Environment

  function environmentPane(target) {
    const versions = xcodeVersions();
    const value = target.xcode.trim();
    const options = versions.map(({ version, names }, index) => [version, `Xcode ${version}${index === 0 ? ' (newest)' : ''} · on ${listText(names)}`]);
    const xcode = pickerWithOther({
      label: 'Xcode version',
      value,
      options,
      unknownLabel: (text) => `Xcode ${text} · no Mac has it`,
      placeholder: '27.2',
      hint: 'Matched as a prefix: 27 picks any installed 27.x.',
      note: [
        machines !== null && versions.length === 0
          ? h('p', { class: 'wf-note wf-note-warning' }, 'No Mac has reported Xcode yet. ', h('a', { href: '/machines', 'data-link': true }, 'Add a Mac'))
          : null,
        // The placeholder note, while the version is still the placeholder.
        value && value === firstSuggested()?.xcode ? guessNotes(notes().xcode) : null,
      ],
      onChange: (text) => { target.xcode = text; },
      invalid: () => !target.xcode.trim(),
    });
    const team = textInput(target.team, (text) => { target.team = text; }, { placeholder: 'e.g. YL78V8PY6H', mono: true });
    const suggestedTeam = firstSuggested()?.teamID;
    return {
      header: header({ icon: 'environment', title: 'Environment', subtitle: 'Where and with what the workflow builds.' }),
      body: h('div', { class: 'wf-form' },
        xcode,
        wfField({
          label: 'Team ID', control: team,
          hint: suggestedTeam && suggestedTeam === target.team.trim() ? 'From the project.' : 'Signs with this team; empty uses the project’s.',
        }),
        toolsField(target),
        wfField({
          label: 'Environment variables',
          control: h('p', { class: 'wf-note' }, 'Variables and secrets belong to the app, not a workflow: set them in ',
            h('a', { href: base, 'data-link': true }, `${app.name}’s Environment`), '.'),
        })),
    };
  }

  function toolsField(target) {
    const reported = new Map();
    for (const machine of machines ?? []) {
      for (const name of Object.keys(machine.report?.tools ?? {})) {
        reported.set(name, [...(reported.get(name) ?? []), machine.name]);
      }
    }
    const names = unique([...reported.keys(), ...target.tools]).sort();
    let adding = false;
    const element = h('div', { class: 'wf-field' });
    function draw() {
      const rows = names.map((name) => checkRow({
        title: name,
        detail: reported.has(name) ? `On ${listText(reported.get(name))}` : 'No Mac reports it',
        checked: target.tools.includes(name),
        onChange: (on) => {
          const index = target.tools.indexOf(name);
          if (on && index < 0) target.tools.push(name);
          if (!on && index >= 0) target.tools.splice(index, 1);
          changed();
        },
      }));
      const input = h('input', {
        class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', placeholder: 'Tool name, e.g. xcodegen',
        'aria-label': 'Tool name',
        onKeydown: (event) => {
          if (event.key === 'Enter' && !event.isComposing) {
            event.preventDefault();
            const name = input.value.trim();
            if (name && !names.includes(name)) names.push(name);
            if (name && !target.tools.includes(name)) target.tools.push(name);
            names.sort();
            adding = false;
            draw();
            changed();
          } else if (event.key === 'Escape') {
            event.stopPropagation();
            adding = false;
            draw();
          }
        },
      });
      const add = adding
        ? h('li', { class: 'wf-new-group' }, input, h('p', { class: 'wf-field-hint' }, 'Return adds it.'))
        : h('li', null, h('button', {
          type: 'button', class: 'wf-add-row',
          onClick: () => { adding = true; draw(); element.querySelector('.wf-new-group input')?.focus(); },
        }, plusGlyph(), 'Add Tool'));
      replaceChildren(element,
        h('span', { class: 'wf-field-label', id: 'wf-tools-label' }, 'Required tools'),
        h('ul', { class: 'wf-checklist', 'aria-labelledby': 'wf-tools-label' }, rows, add),
        h('p', { class: 'wf-field-hint' }, 'Only Macs with these tools run this workflow.'),
        guessNotes(notes().tools));
    }
    draw();
    return element;
  }

  // MARK: Start conditions

  /** Manual start, the only start condition: who can start it, and from which branches. */
  function startPane(target) {
    const known = branches.state; // undefined while loading, null when unknown
    const defaultBranch = known?.defaultBranch ?? null;
    const custom = Array.isArray(target.branches);
    const element = h('div', { class: 'wf-form' });
    function draw(focus) {
      const list = custom ? target.branches : [];
      const suggested = firstExactBranch(target) ?? defaultBranch;
      const kind = segmented({
        label: 'Source branch', value: Array.isArray(target.branches) ? 'custom' : 'any',
        options: [['any', 'Any Branch'], ['custom', 'Custom Branches']],
        onChange: (value) => {
          target.branches = value === 'any' ? 'any' : [defaultBranch ?? 'main'];
          renderDetail();
          changed();
          detail.querySelector(`.wf-segmented [data-value="${value}"]`)?.focus();
        },
      });
      const rows = list.map((name, index) => h('li', { class: 'wf-pattern' },
        h('span', { class: 'wf-pattern-name mono' }, name),
        name === defaultBranch ? h('span', { class: 'wf-check-tag' }, 'default') : name.includes('*') ? h('span', { class: 'wf-check-tag' }, 'pattern') : null,
        h('button', {
          type: 'button', class: 'button button-plain button-small wf-destructive', 'aria-label': `Remove ${name}`,
          onClick: () => { target.branches.splice(index, 1); draw('add'); changed(); },
        }, 'Remove')));
      // Add: a branch of the repository (the default first), or Other… for a pattern such as release/*.
      const options = (known?.branches ?? []).filter((name) => !list.includes(name));
      let adder;
      const add = (value) => {
        const name = value.trim();
        if (!name || list.includes(name)) return;
        target.branches.push(name);
        draw('add');
        changed();
      };
      if (custom) {
        const select = h('select', { class: 'select', 'aria-label': 'Add a branch' },
          h('option', { value: '' }, known === undefined ? 'Loading branches…' : 'Add a branch…'),
          options.map((name) => h('option', { value: name }, name === defaultBranch ? `${name} (default)` : name)),
          h('option', { value: OTHER }, 'Other: a name or pattern…'));
        const input = h('input', {
          class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', hidden: true,
          placeholder: 'release/*', 'aria-label': 'Branch name or pattern',
          onKeydown: (event) => {
            if (event.key === 'Enter' && !event.isComposing) { event.preventDefault(); add(input.value); }
            if (event.key === 'Escape') { event.stopPropagation(); input.hidden = true; select.value = ''; select.focus(); }
          },
        });
        select.addEventListener('change', () => {
          if (select.value === OTHER) { input.hidden = false; input.focus(); return; }
          add(select.value);
        });
        adder = h('div', { class: 'wf-field' }, select, input,
          h('p', { class: 'wf-field-hint' }, '* matches within one level (release/*), ** across levels. Return adds a typed name.'));
      }
      replaceChildren(element,
        explain(suggested
          ? ['Start builds from Hangar, the CLI or a skill. Deploy starts from ', { strong: suggested },
            custom && list.length > 1 ? ' unless you pick another of these branches.' : custom ? '.' : ' (the default branch) unless you pick another.']
          : ['Start builds from Hangar, the CLI or a skill, from any branch you pick.']),
        wfField({ label: 'Source branch', control: kind }),
        custom ? h('div', { class: 'wf-field' },
          h('span', { class: 'wf-field-label', id: 'wf-branches-label' }, 'Branches'),
          rows.length ? h('ul', { class: 'wf-checklist', 'aria-labelledby': 'wf-branches-label' }, rows) : null,
          adder) : null);
      if (focus === 'add') element.querySelector('select[aria-label="Add a branch"]')?.focus();
    }
    draw();
    if (known === undefined) branches.load().then(() => { if (selection.kind === 'start' && element.isConnected) renderDetail(); });
    return {
      header: header({ icon: 'start', tone: 'start', title: 'Manual Start', subtitle: 'The only start condition: builds start when you deploy.' }),
      body: element,
    };
  }

  // MARK: Actions

  function actionPane(target, index) {
    const action = target.actions[index];
    const isTest = action.kind === 'test';
    const tools = [
      button('Duplicate', {
        kind: 'plain', class: 'button button-plain button-small',
        onClick: () => {
          target.actions.splice(index + 1, 0, { ...action });
          select({ kind: 'action', index: index + 1 });
          changed();
        },
      }),
    ];
    const explainBox = h('div', null, explain(isTest ? describeTest(action) : describeArchive(action, target)));
    const redraw = () => {
      replaceChildren(explainBox, explain(isTest ? describeTest(action) : describeArchive(action, target)));
      changed();
    };
    // Platform first: a pop-up of every platform, those without a detected scheme greyed with the reason. The scheme
    // list below follows it; a scheme that doesn't build for the new platform is cleared, to be picked again, and so
    // is a simulator picked for the old one.
    const platformSelect = h('select', {
      class: 'select',
      dataset: { field: 'platform' },
      onChange: () => {
        const value = platformSelect.value;
        action.platform = value;
        const schemes = currentSchemes(value, action.kind).map((scheme) => scheme.name);
        if (suggestion?.schemes?.length && !schemes.includes(action.scheme)) action.scheme = '';
        if (action.export === 'developer-id' && value !== 'macos') action.export = 'app-store-connect';
        action.destination = '';
        renderDetail();
        changed();
        detail.querySelector(`.wf-form select[data-field="${action.scheme ? 'platform' : 'scheme'}"]`)?.focus();
      },
    }, PLATFORMS.map(([value, label]) => {
      const available = platformHasSchemes(suggestion?.schemes, value) || value === action.platform;
      return h('option', { value, disabled: !available },
        available ? label : `${label} — no scheme for ${label} in this repository`);
    }));
    platformSelect.value = action.platform;
    const platformNote = action.platform === 'macos' ? notes().platforms[action.scheme.trim()] : null;
    const platform = wfField({ label: 'Platform', control: platformSelect, note: platformNote ? guessNotes([platformNote]) : null });
    const scheme = schemeField(action, redraw);
    const fields = isTest ? testFields(action, redraw) : [distributionField(action, target, redraw)];
    return {
      header: header({
        icon: isTest ? 'test' : 'archive', title: actionTitle(action),
        tools,
      }),
      // The destructive action comes last, apart from the rest.
      body: h('div', { class: 'wf-form' }, explainBox, platform, scheme, fields,
        h('div', { class: 'wf-danger-zone' },
          button(`Delete ${isTest ? 'Test' : 'Archive'} Action…`, {
            kind: 'plain', class: 'button button-plain wf-destructive wf-flush-start', onClick: () => removeAction(index),
          }))),
    };
  }

  async function removeAction(index) {
    const target = model();
    const action = target.actions[index];
    const confirmed = await confirm({
      title: `Delete ${actionTitle(action)}?`,
      message: `${action.scheme.trim() || 'This action'} is no longer ${action.kind === 'test' ? 'tested' : 'archived'} by this workflow once you save.`,
      confirmLabel: 'Delete',
      destructive: true,
    });
    if (!confirmed) return;
    target.actions.splice(index, 1);
    // A TestFlight step without any archive left has nothing to upload.
    if (!target.actions.some((other) => other.kind !== 'test')) target.testflightOn = false;
    selection = target.actions.length ? { kind: 'action', index: Math.max(0, index - 1) } : { kind: 'general' };
    renderEditor();
    sidebar.querySelector(`[data-item="${itemKey(selection)}"]`)?.focus();
  }

  function schemeField(action, onChange) {
    const schemes = currentSchemes(action.platform, action.kind);
    const apps = schemes.filter((scheme) => scheme.isApplication);
    const others = schemes.filter((scheme) => !scheme.isApplication);
    // A scheme of unknown platform is listed under every platform, saying so.
    const label = (scheme) => [scheme.name, action.kind === 'test' && scheme.hasTests && 'has tests', scheme.unverified && 'platform not detected']
      .filter(Boolean).join(' · ');
    const groupsOfOptions = action.kind === 'test'
      ? [['', schemes.map((scheme) => [scheme.name, label(scheme)])]]
      : [['', apps.map((scheme) => [scheme.name, label(scheme)])], ['Other schemes', others.map((scheme) => [scheme.name, label(scheme)])]];
    const known = schemes.find((scheme) => scheme.name === action.scheme);
    // What detection guessed about the schemes, while the action still has one it suggested.
    const suggested = (firstSuggested()?.actions ?? []).map((item) => item.scheme);
    return pickerWithOther({
      label: 'Scheme',
      field: 'scheme',
      value: action.scheme,
      note: suggested.includes(action.scheme.trim()) ? guessNotes(notes().schemes) : null,
      groups: groupsOfOptions,
      placeholder: 'Scheme name',
      emptyLabel: 'Choose a scheme',
      hint: action.kind === 'test' && known && !known.hasTests
        ? 'No test target was found for this scheme; the build fails if it has no tests.'
        : suggestion ? null : 'Reading the repository for its schemes…',
      onChange: (value) => { action.scheme = value; onChange(); },
      invalid: () => !action.scheme.trim(),
      rerenderOnChange: true,
    });
  }

  function distributionField(action, target, onChange) {
    const ipa = action.platform === 'macos' ? '.pkg' : '.ipa';
    const field = h('div', { class: 'wf-field' });
    function draw() {
      replaceChildren(field,
        h('span', { class: 'wf-field-label' }, 'Distribution'),
        choiceCards({
          legend: 'Distribution', value: action.export,
          options: [
            {
              value: 'app-store-connect', title: 'TestFlight and App Store',
              detail: `Signs for App Store distribution and keeps the ${ipa}. Needed for TestFlight.`,
            },
            {
              value: 'developer-id', title: 'Developer ID',
              detail: action.platform === 'macos'
                ? target.testflightOn
                  ? 'Signs the Mac app for direct download. Can’t go to TestFlight, which this workflow uploads to.'
                  : 'Signs the Mac app for direct download, outside the App Store. Can’t go to TestFlight.'
                : 'Mac apps only.',
              disabled: action.platform !== 'macos',
            },
          ],
          onChange: (value) => {
            action.export = value;
            draw();
            onChange();
            field.querySelector('input:checked')?.focus();
          },
        }));
    }
    draw();
    return field;
  }

  function testFields(action, onChange) {
    const plans = suggestion?.testPlans ?? [];
    const plan = plans.length
      ? pickerWithOther({
        label: 'Test plan', value: action.testPlan.trim(),
        options: [['', 'The scheme’s default plan'], ...plans.map((name) => [name, name])],
        placeholder: 'Test plan name',
        onChange: (value) => { action.testPlan = value; onChange(); },
      })
      : wfField({
        label: 'Test plan',
        control: textInput(action.testPlan, (value) => { action.testPlan = value; onChange(); }, { placeholder: 'The scheme’s default plan' }),
        hint: 'Optional. Leave empty to run the scheme’s default test plan.',
      });
    let destination;
    if (action.platform === 'macos') {
      destination = wfField({ label: 'Destination', control: h('div', { class: 'wf-readonly' }, 'This Mac'), hint: 'macOS tests run on the Mac that builds them.' });
    } else {
      const device = testDestinationText({ platform: action.platform, destination: '' }).replace(/^the /, '');
      const runtimes = unique((machines ?? []).flatMap((machine) => machine.report?.simulatorRuntimes ?? [])
        .filter((runtime) => runtime.toLowerCase().startsWith(platformName(action.platform).toLowerCase())));
      destination = pickerWithOther({
        label: 'Destination',
        value: (action.destination ?? '').trim().toLowerCase() === 'recommended' ? '' : (action.destination ?? '').trim(),
        options: [['', `Recommended (${device})`]],
        placeholder: 'Simulator name, e.g. iPhone 17 Pro',
        unknownLabel: (text) => text,
        onChange: (value) => { action.destination = value; onChange(); },
        note: machines === null ? null : runtimes.length
          ? h('p', { class: 'wf-note' }, `Your Macs have ${listText(runtimes)} simulators.`)
          : h('p', { class: 'wf-note wf-note-warning' }, `No Mac reports a ${platformName(action.platform)} simulator yet; the build waits for one.`),
      });
    }
    return [plan, destination];
  }

  // MARK: TestFlight

  function testFlightPane(target) {
    const t = target.testflight;
    const explainBox = h('div', null, explain(describeTestFlight(target)));
    const redraw = () => {
      replaceChildren(explainBox, explain(describeTestFlight(target)));
      changed();
    };
    const files = suggestion?.whatToTestFiles ?? [];
    const locales = files.map((path) => path.replace(/^.*WhatToTest\./, '').replace(/\.txt$/, ''));
    // One grouped box: "Wait for processing", and nested under it, indented to its label, everything that needs the
    // processed build. With the wait off the nested settings go, and a line says why.
    const box = h('div', { class: 'wf-switches' });
    function draw(focusWait) {
      const wait = switchField({
        label: 'Wait for processing',
        hint: 'Hangar waits for App Store Connect to process the build (usually 5–30 minutes) so it can hand it to testers.',
        checked: t.waitForProcessing,
        onChange: (on) => {
          t.waitForProcessing = on;
          draw(true);
          redraw();
        },
      });
      let nested;
      if (t.waitForProcessing) {
        const minutes = /^[1-9]\d*$/.test(t.timeout.trim()) ? t.timeout.trim() : '60';
        const choices = ['30', '60', '120'].includes(minutes) ? ['30', '60', '120'] : ['30', '60', '120', minutes];
        const timeout = h('select', {
          class: 'select wf-timeout', id: 'wf-timeout',
          onChange: () => { t.timeout = timeout.value; changed(); },
        }, choices.map((value) => h('option', { value }, value === '120' ? '2 hours' : `${value} minutes`)));
        timeout.value = minutes;
        const groupsField = h('div', { class: 'wf-field' },
          h('span', { class: 'wf-field-label' }, 'Groups'),
          groupPicker({ store: groups, selected: t.groups, onChange: () => { redraw(); renderSidebar(); } }));
        const whatToTest = switchField({
          label: 'What to Test',
          hint: suggestion
            ? files.length
              ? `From TestFlight/WhatToTest.<locale>.txt next to the project: found ${listText(locales)}.`
              : 'From TestFlight/WhatToTest.<locale>.txt next to the project. The repository has none yet, so nothing is set.'
            : 'From TestFlight/WhatToTest.<locale>.txt next to the project.',
          checked: t.whatToTest,
          onChange: (on) => { t.whatToTest = on; changed(); },
        });
        const review = switchField({
          label: 'Submit for external review',
          hint: 'Sends the build to Beta App Review, which external groups need.',
          checked: t.submitForExternalReview,
          onChange: (on) => { t.submitForExternalReview = on; changed(); },
        });
        nested = h('div', { class: 'wf-nested' },
          h('div', { class: 'wf-inline-field' }, h('label', { class: 'wf-field-label', for: 'wf-timeout' }, 'Give up after'), timeout),
          groupsField,
          h('div', { class: 'wf-switch-list' }, whatToTest.element, review.element));
      } else {
        nested = h('p', { class: 'wf-nested wf-dependent-note' }, 'Groups, What to Test and review need the processed build, so they are off. The build still goes to TestFlight.');
      }
      replaceChildren(box, wait.element, nested);
      if (focusWait) box.querySelector('input[role="switch"]')?.focus();
    }
    draw();
    return {
      header: header({ icon: 'testflight', title: 'TestFlight Internal Testing' }),
      body: h('div', { class: 'wf-form' }, explainBox, box,
        t.requiresApproval ? h('p', { class: 'wf-note' }, 'This step waits for approval (requires-approval in the file).') : null,
        h('div', { class: 'wf-danger-zone' },
          button('Delete Post-Action…', { kind: 'plain', class: 'button button-plain wf-destructive wf-flush-start', onClick: removeTestFlight }))),
    };
  }

  async function removeTestFlight() {
    const confirmed = await confirm({
      title: 'Delete TestFlight Internal Testing?',
      message: 'Archives stay on the build page and are no longer uploaded once you save.',
      confirmLabel: 'Delete',
      destructive: true,
    });
    if (!confirmed) return;
    model().testflightOn = false;
    selection = { kind: 'general' };
    renderEditor();
  }

  // MARK: Save, YAML and removal

  /** Shows the first item with a problem (from the save bar's status). */
  function showFirstProblem() {
    for (let index = 0; index < models.length; index += 1) {
      const found = problemsOf(index);
      if (!allProblems(found).length) continue;
      current = index;
      selection = firstProblemItem(found);
      view = 'detail';
      renderEditor({ focusDetail: true });
      detail.scrollIntoView?.({ block: 'start', behavior: 'smooth' });
      return;
    }
  }

  /** Cancel: back to the workflow as last saved, after asking; a workflow never saved leaves for the app page. */
  async function cancelEdits() {
    if (!isDirty()) return;
    const confirmed = await confirm({
      title: 'Discard Changes?',
      message: saved === null ? 'This workflow has not been saved.' : 'Your edits since the last save are lost.',
      confirmLabel: 'Discard',
      cancelLabel: 'Keep Editing',
      destructive: true,
    });
    if (!confirmed) return;
    if (!stored) {
      saved = snapshot();
      navigate(base);
      return;
    }
    const name = model()?.name.trim();
    models = modelsFromFile(stored.workflows);
    saved = snapshot();
    current = Math.max(0, models.findIndex((other) => other.name === name));
    selection = { kind: 'general' };
    view = 'list';
    banner = null;
    renderEditor();
    toast('Changes discarded', 'info');
  }

  // ⌘S (Ctrl-S elsewhere) saves, as in a document.
  const onKeydown = (event) => {
    if (event.key !== 's' || !(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) return;
    if (!models.length || document.querySelector('.sheet-backdrop')) return;
    event.preventDefault();
    if (!saveButton.disabled) save();
    else if (status.dataset.problems) showFirstProblem();
  };
  document.addEventListener('keydown', onKeydown);
  context.onCleanup(() => document.removeEventListener('keydown', onKeydown));

  async function save() {
    // Every workflow is checked; the first problem's item is shown.
    for (let index = 0; index < models.length; index += 1) {
      const found = problemsOf(index);
      const list = allProblems(found);
      if (!list.length) continue;
      current = index;
      selection = firstProblemItem(found);
      view = 'detail';
      const others = models.length > 1 ? ` in “${models[index].name.trim() || 'Untitled'}”` : '';
      banner = {
        kind: 'error',
        text: `${list.length === 1 ? 'One problem blocks' : `${list.length} problems block`} saving${others}. Items marked ! need a fix.`,
      };
      renderEditor({ focusDetail: true });
      // The banner and the item both in view, below the sticky top bar.
      window.scrollTo({ top: Math.max(0, bannerSlot.getBoundingClientRect().top + window.scrollY - 72), behavior: 'smooth' });
      return;
    }
    busy = true;
    refresh();
    try {
      stored = await api.put(`${base}/workflow-file`, { yaml: workflowToYAML(fileFromModels(models)) });
      const name = model().name.trim();
      models = modelsFromFile(stored.workflows);
      current = Math.max(0, models.findIndex((other) => other.name === name));
      saved = snapshot();
      busy = false;
      banner = savedBanner(model().name.trim());
      renderEditor();
    } catch (error) {
      busy = false;
      if (error.code === 'aborted') return;
      banner = { kind: 'error', text: error.message };
      renderEditor();
    }
  }

  function firstProblemItem(found) {
    if (found.workflow.length || found.general.length) return { kind: 'general' };
    if (found.environment.length) return { kind: 'environment' };
    if (found.start.length) return { kind: 'start' };
    const index = found.actions.findIndex((list) => list.length);
    if (index >= 0) return { kind: 'action', index };
    return { kind: 'testflight' };
  }

  function showYAML() {
    const text = workflowToYAML(fileFromModels(models));
    const code = h('pre', { class: 'wf-yaml', tabindex: '0', 'aria-label': '.hangar.yml' }, h('code', null, text));
    sheet({
      title: '.hangar.yml',
      body: [h('p', { class: 'wf-note' }, 'The workflow file as Hangar stores it. Commit it as .hangar.yml at the repository root to keep it with the code.'), code],
      actions: [
        { label: 'Done', kind: 'secondary' },
        {
          label: 'Copy', kind: 'primary',
          onClick: async () => {
            if (await copyText(text)) {
              toast('Copied .hangar.yml', 'success');
              return true;
            }
            selectContents(code);
            toast('The YAML is selected. Press ⌘C to copy it.', 'info');
            return false;
          },
        },
      ],
    });
  }

  async function removeWorkflow() {
    const name = model().name.trim() || 'this workflow';
    if (models.length > 1) {
      const confirmed = await confirm({
        title: `Delete “${name}”?`,
        message: 'The other workflows stay. It is gone once you save.',
        confirmLabel: 'Delete',
        destructive: true,
      });
      if (!confirmed) return;
      models.splice(current, 1);
      current = 0;
      selection = { kind: 'general' };
      view = 'list';
      renderEditor();
      return;
    }
    if (!stored) {
      models = [];
      saved = null;
      banner = null;
      renderStart();
      return;
    }
    const repositoryHasFile = repoFile === undefined || repoFile === null
      ? await api.get(`${base}/workflow-source?repository=1`).then((s) => s?.repositoryHasWorkflowFile ?? null, () => null)
      : repoFile;
    const confirmed = await confirm({
      title: `Delete “${name}”?`,
      message: repositoryHasFile === true
        ? `${app.name} builds with the .hangar.yml in its repository again.`
        : repositoryHasFile === false
          ? `${app.name}’s repository has no .hangar.yml, so deploys fail until you set up a workflow again.`
          : `${app.name} then builds with a .hangar.yml in its repository. Builds fail if it has none.`,
      confirmLabel: repositoryHasFile === false ? 'Delete and Disable Builds' : 'Delete',
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
    models = [];
    saved = null;
    banner = null;
    repoFile = repositoryHasFile;
    renderStart();
    toast('Deleted the workflow', 'success');
  }

  // MARK: Facts from the repository and the Macs

  function firstSuggested() {
    const workflows = suggestion?.workflows?.workflows ?? {};
    return workflows[Object.keys(workflows)[0]] ?? null;
  }

  /** The detector's notes, filed by field (workflow-model.js's `detectionNotes`). */
  function notes() {
    return detectionNotes(suggestion?.notes);
  }

  /** Detected schemes for `platform` (workflow-model.js's `schemesFor`). */
  function currentSchemes(platform, kind) {
    return schemesFor(suggestion?.schemes, platform, kind);
  }

  /** Xcode versions the Macs report, newest first, with the Macs that have each. */
  function xcodeVersions() {
    const byVersion = new Map();
    for (const machine of machines ?? []) {
      for (const xcode of machine.report?.xcodes ?? []) {
        if (!xcode.version) continue;
        byVersion.set(xcode.version, unique([...(byVersion.get(xcode.version) ?? []), machine.name]));
      }
    }
    return [...byVersion.entries()]
      .sort(([a], [b]) => b.localeCompare(a, 'en', { numeric: true }))
      .map(([version, names]) => ({ version, names }));
  }

  // MARK: Fields

  /** A labelled field; `control` gets the label, `hint` and `error` describe it. */
  function wfField({ label, control, hint, error, note }) {
    const id = control.id || `wf-field-${++fieldCount}`;
    const labelled = ['INPUT', 'SELECT', 'TEXTAREA'].includes(control.tagName);
    if (labelled) control.id = id;
    const hintNode = hint ? h('p', { class: 'wf-field-hint', id: `${id}-hint` }, hint) : null;
    if (hintNode && labelled) control.setAttribute('aria-describedby', hintNode.id);
    return h('div', { class: 'wf-field' },
      labelled ? h('label', { class: 'wf-field-label', for: id }, label) : h('span', { class: 'wf-field-label' }, label),
      control, note, error ? h('p', { class: 'wf-field-error' }, error) : null, hintNode);
  }

  function textInput(value, onInput, { placeholder, mono = false, invalid } = {}) {
    const input = h('input', {
      class: ['input', mono && 'mono'], type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
      value, placeholder,
      onInput: (event) => {
        onInput(event.target.value);
        if (invalid) input.setAttribute('aria-invalid', String(invalid()));
        changed();
      },
    });
    if (invalid?.()) input.setAttribute('aria-invalid', 'true');
    return input;
  }

  /**
   * A pop-up of `options` (`[value, label]`, or `groups` of them) plus "Other…", which reveals a text field for any
   * value. A value not among the options shows as its own entry (`unknownLabel`), so nothing is lost. `field` names
   * the pop-up (`data-field`), for focusing it after a redraw.
   */
  function pickerWithOther({
    label, value, options = [], groups: optionGroups, placeholder, hint, note, onChange, invalid, emptyLabel, unknownLabel, field,
  }) {
    const element = h('div', { class: 'wf-field' });
    const all = optionGroups ?? [['', options]];
    const known = all.flatMap(([, list]) => list.map(([optionValue]) => optionValue));
    let other = false;
    let text = value;
    function draw(focus) {
      const id = `wf-field-${++fieldCount}`;
      const select = h('select', {
        class: 'select', id, dataset: field ? { field } : null,
        onChange: () => {
          if (select.value === OTHER) {
            other = true;
            draw('input');
            return;
          }
          other = false;
          value = select.value;
          text = value;
          onChange(value);
          draw('select');
          changed();
        },
      });
      if (!value && !known.includes('') && emptyLabel) select.append(h('option', { value: '', disabled: true }, emptyLabel));
      for (const [groupLabel, list] of all) {
        const items = list.map(([optionValue, optionLabel]) => h('option', { value: optionValue }, optionLabel));
        if (!items.length) continue;
        if (groupLabel) select.append(h('optgroup', { label: groupLabel }, items));
        else select.append(...items);
      }
      const isKnown = known.includes(value);
      if (value && !isKnown && !other) select.append(h('option', { value }, unknownLabel ? unknownLabel(value) : value));
      select.append(h('option', { value: OTHER }, 'Other…'));
      select.value = other ? OTHER : value;
      if (invalid?.()) select.setAttribute('aria-invalid', 'true');
      const input = other ? h('input', {
        class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', value: text, placeholder,
        'aria-label': `${label}, other`,
        onInput: (event) => {
          text = event.target.value;
          value = text;
          onChange(text);
          if (invalid) input.setAttribute('aria-invalid', String(invalid()));
          changed();
        },
        onKeydown: (event) => {
          if (event.key === 'Escape' && known.length) {
            event.stopPropagation();
            other = false;
            draw('select');
          }
        },
      }) : null;
      if (input && invalid?.()) input.setAttribute('aria-invalid', 'true');
      const hintNode = hint ? h('p', { class: 'wf-field-hint', id: `${id}-hint` }, hint) : null;
      if (hintNode) select.setAttribute('aria-describedby', hintNode.id);
      replaceChildren(element, h('label', { class: 'wf-field-label', for: id }, label), select, input, note, hintNode);
      if (focus === 'input') input?.focus();
      if (focus === 'select') select.focus();
    }
    draw();
    return element;
  }

  renderEditor();
  return element;
}

// MARK: Helpers

let fieldCount = 0;

function sameItem(a, b) {
  return a.kind === b.kind && (a.kind !== 'action' || a.index === b.index);
}

function itemKey(item) {
  return item.kind === 'action' ? `action-${item.index}` : item.kind;
}

function unique(items) {
  return items.filter((item, index) => items.indexOf(item) === index);
}

function listText(items) {
  if (items.length <= 1) return items.join('');
  return `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`;
}

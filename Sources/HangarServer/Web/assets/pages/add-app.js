// The Add App sheet: pick the GitHub repository, then the app Hangar found in it (matched to App Store Connect by
// bundle ID), then review and add. Nothing is typed in the common case.

import { api, ApiError, seg } from '../api.js';
import {
  button, checkBadge, confirm, field, h, relativeTime, replaceChildren, sheet, spinner, svg, toast,
} from '../ui.js';
import {
  filterRepositories, parseRepositoryURL, rankAppStoreConnectApps, rankRepositories,
} from '../repo-ranking.js';
import { appIcon, expectIcon, isHTTPS } from './apps.js';

const PLATFORM_NAMES = { ios: 'iOS', macos: 'macOS', visionos: 'visionOS', tvos: 'tvOS', watchos: 'watchOS' };
const ASC_APPS_URL = 'https://appstoreconnect.apple.com/apps';
const STEPS = [['repo', 'Repository'], ['app', 'App'], ['review', 'Review']];

const textAttrs = { class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off' };

/**
 * Opens the sheet; `onAdded(app, { hasWorkflowFile, bundleID })` runs after the server created the app:
 * whether the repository has its own .hangar.yml, and the bundle ID of the app picked.
 */
export function openAddAppSheet({ onAdded } = {}) {
  const state = {
    step: 'repo',
    repo: null, // { owner, repo, fullName, htmlURL, isPrivate }
    inspection: null, // RepositoryInspection of `repo`
    app: null, // the DetectedApp picked
    manual: null, // { name, ascID, for } typed by hand instead (`for`: the detected app it is for, or null)
    picking: null, // the detected app whose App Store Connect picker is open
    manualFor: undefined, // the detected app the typed-ID form is for; null: none in particular; undefined: closed
    autoMatched: false, // step 2 was decided by Hangar: one app in the repository, found in App Store Connect
  };
  let repos = null; // GitHubRepo[], loaded once
  let reposError = null;
  let ascConfigured = null;
  let inspecting = null; // the AbortController of the running inspection
  let ascApps = null; // the team's App Store Connect apps, loaded when a picker first opens

  const steps = h('ol', { class: 'add-app-steps' });
  const content = h('div', { class: 'add-app-content' });
  const handle = sheet({
    title: 'Add App',
    anchor: 'top', // the steps differ in height: the top edge stays put and the sheet grows downwards
    body: h('div', { class: 'add-app' }, steps, content),
    actions: [],
    beforeDismiss: () => (state.repo ? confirm({
      title: 'Discard This App?',
      message: 'The repository and app you picked are not added yet.',
      confirmLabel: 'Discard',
      destructive: true,
    }) : true),
    onClose: () => inspecting?.abort(),
  });
  const sheetElement = handle.element;

  function go(step) {
    state.step = step;
    handle.setError(null);
    render();
  }

  function render() {
    const at = STEPS.findIndex(([id]) => id === state.step);
    replaceChildren(steps, STEPS.map(([id, label], index) => {
      const done = index < at;
      return h('li', {
        class: ['add-app-step', id === state.step && 'current', done && 'done'],
        'aria-current': id === state.step ? 'step' : null,
      },
      done ? checkBadge('add-app-step-number') : h('span', { class: 'add-app-step-number', 'aria-hidden': 'true' }, String(index + 1)),
      h('span', { class: 'add-app-step-text' },
        h('span', null, label, done ? h('span', { class: 'visually-hidden' }, ' (done)') : null),
        id === 'app' && done && state.autoMatched ? h('span', { class: 'add-app-step-caption' }, 'Matched automatically') : null));
    }));
    if (state.step === 'repo') renderRepoStep();
    else if (state.step === 'app') renderAppStep();
    else renderReviewStep();
  }

  // MARK: Step 1: repository

  function renderRepoStep() {
    const cancel = { label: 'Cancel', kind: 'cancel' };
    if (repos === null && reposError === null) {
      replaceChildren(content, h('div', { class: 'picker-status' }, spinner('Loading repositories'),
        h('p', { class: 'picker-status-label' }, 'Loading your repositories…')));
      handle.setActions([cancel]);
      api.get('/github/repos').then((list) => { repos = list ?? []; }, (error) => { reposError = error; })
        .then(() => { if (state.step === 'repo' && sheetElement.isConnected) render(); });
      return;
    }

    const urlInput = h('input', {
      ...textAttrs, type: 'url', inputmode: 'url', placeholder: 'https://github.com/owner/repo',
      'aria-label': 'Repository URL',
    });
    const useURL = () => {
      const parsed = parseRepositoryURL(urlInput.value);
      if (!parsed) {
        urlInput.setAttribute('aria-invalid', 'true');
        urlInput.focus();
        handle.setError('Enter the repository as https://github.com/owner/repo.');
        return;
      }
      pickRepo({ ...parsed, htmlURL: `https://github.com/${parsed.fullName}`, isPrivate: false, pasted: true });
    };
    urlInput.addEventListener('input', () => urlInput.removeAttribute('aria-invalid'));
    urlInput.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !event.isComposing) {
        event.preventDefault();
        useURL();
      }
    });
    const urlRow = h('div', { class: 'add-app-url' },
      field({ label: 'Repository URL', hint: 'A GitHub repository the token in Settings can read.', control: urlInput }),
      button('Use This Repository', { onClick: useURL }));

    if (reposError) {
      const code = reposError instanceof ApiError ? reposError.code : null;
      const link = () => h('a', { href: '/settings', 'data-link': true }, 'Settings');
      replaceChildren(content,
        h('div', { class: 'add-app-callout' },
          code === 'github_not_configured'
            ? ['Add a GitHub token in ', link(), ' to pick from your repositories, or paste the repository’s URL.']
            : code === 'github_unauthorized'
              ? ['GitHub refused the token. Set a new one in ', link(), ', or paste the repository’s URL.']
              : `Your repositories could not be listed: ${reposError.message} Paste the repository’s URL instead.`),
        urlRow);
      handle.setActions([cancel]);
      urlInput.focus();
      return;
    }

    const ranked = rankRepositories(repos).repos;
    const search = h('input', {
      class: 'input', type: 'search', placeholder: 'Search repositories', autocomplete: 'off', spellcheck: 'false',
      'aria-label': 'Search repositories', 'aria-keyshortcuts': '/',
    });
    const list = h('ul', { class: 'pick-list', 'aria-label': 'Repositories' });
    const showURL = h('button', { type: 'button', class: 'link-button' }, 'Paste a URL instead');
    urlRow.hidden = true;
    showURL.addEventListener('click', () => {
      urlRow.hidden = false;
      showURL.hidden = true;
      urlInput.focus();
    });

    function renderList() {
      const matches = filterRepositories(ranked, search.value);
      replaceChildren(list, matches.length === 0
        ? h('li', { class: 'pick-empty' }, ranked.length === 0 ? 'The token sees no repositories.' : 'No matching repositories.')
        : matches.map((repo) => h('li', null, repoItem(repo))));
    }

    function repoItem(repo) {
      const [owner, name] = repo.fullName.split('/');
      return h('button', {
        type: 'button',
        class: ['pick-item', repo.archived && 'archived'],
        'aria-pressed': String(state.repo?.fullName === repo.fullName),
        onClick: () => pickRepo({ owner, repo: name, fullName: repo.fullName, htmlURL: repo.htmlURL, isPrivate: repo.isPrivate }),
      },
      h('span', { class: 'pick-item-text' },
        h('span', { class: 'pick-item-name' },
          // Owner and name are one run of text; the flex gap only separates the badges.
          h('span', { class: 'pick-item-title' }, h('span', { class: 'secondary' }, `${owner}/`), name),
          repo.isPrivate ? lockBadge() : null,
          repo.archived ? h('span', { class: 'pick-badge' }, 'Archived') : null),
        repo.description ? h('span', { class: 'pick-item-detail' }, repo.description) : null),
      repo.pushedAt ? h('span', { class: 'pick-item-time' }, `updated ${relativeTime(repo.pushedAt)}`) : null);
    }

    search.addEventListener('input', renderList);
    listKeys(search, list);
    renderList();
    replaceChildren(content, search, list, h('div', { class: 'add-app-links' }, showURL), urlRow);
    handle.setActions([cancel]);
    search.focus();
  }

  function pickRepo(repo) {
    state.autoMatched = false;
    if (state.repo?.fullName !== repo.fullName) {
      state.inspection = null;
      state.app = null;
      state.manual = null;
      state.picking = null;
      state.manualFor = undefined;
    }
    state.repo = repo;
    go('app');
  }

  // MARK: Step 2: the app in the repository

  const settingsLink = () => h('a', { href: '/settings', 'data-link': true }, 'Settings');
  const backToRepo = { label: 'Back', kind: 'secondary', onClick: () => { go('repo'); return false; } };

  function renderAppStep() {
    if (!state.inspection) {
      replaceChildren(content, h('div', { class: 'picker-status' }, spinner(`Reading ${state.repo.fullName}`),
        h('p', { class: 'picker-status-label' }, `Reading ${state.repo.fullName}…`)));
      handle.setActions([backToRepo]);
      inspect();
      return;
    }
    const inspection = state.inspection;
    const { apps } = inspection;
    // The form for typing the ID: under the picker of the app it is for, else at the bottom.
    const manual = state.manualFor !== undefined ? manualForm(state.manualFor) : null;
    const next = { label: 'Next', kind: 'primary', onClick: () => { manual?.submit(); return false; } };
    const showManual = h('button', {
      type: 'button',
      class: 'link-button',
      onClick: () => {
        state.picking = null;
        state.manualFor = null;
        renderAppStep();
      },
    }, 'Enter the App Store Connect app ID by hand');
    // Typing the ID is the fallback for an app Hangar could not match; with a match it is only noise.
    const matched = apps.some((app) => app.appStoreConnect && !app.appStoreConnect.registered);
    showManual.hidden = state.manualFor === null || matched;

    replaceChildren(content,
      inspection.hasWorkflowFile
        ? h('div', { class: 'add-app-callout' },
          `${state.repo.fullName} has its own .hangar.yml: builds use it until you define a workflow in Hangar.`)
        : null,
      apps.length === 0
        ? h('div', { class: 'add-app-callout' }, `Hangar found no app target in ${state.repo.fullName}. Enter the app by hand.`)
        : h('ul', { class: 'detected-list', 'aria-label': 'Apps in the repository' },
          apps.map((app) => h('li', null,
            detectedCard(app),
            state.picking === app ? ascPicker(app) : null,
            state.manualFor === app ? manual.element : null))),
      ascConfigured === false
        ? h('div', { class: 'add-app-callout' }, 'Add your App Store Connect key in ', settingsLink(),
          ' to find these apps in App Store Connect.')
        : null,
      inspection.notes?.length
        ? h('div', { class: 'add-app-callout add-app-notes' },
          h('p', { class: 'add-app-notes-title' }, 'What Hangar found'),
          h('ul', null, inspection.notes.map((note) => h('li', null, note))))
        : null,
      h('div', { class: 'add-app-links' }, showManual),
      state.manualFor === null ? manual.element : null);
    const takeSelected = { label: 'Next', kind: 'primary', onClick: () => { go('review'); return false; } };
    handle.setActions(manual ? [backToRepo, next] : state.app?.appStoreConnect ? [backToRepo, takeSelected] : [backToRepo]);
    listKeys(null, content.querySelector('.detected-list'));
    if (manual) manual.focus();
    else if (state.picking) content.querySelector('.asc-search')?.focus();
    else (content.querySelector('.detected-item:not(:disabled), .detected-pick') ?? showManual).focus();
  }

  async function inspect() {
    inspecting?.abort();
    const controller = new AbortController();
    inspecting = controller;
    const { owner, repo } = state.repo;
    try {
      const [inspection, settings] = await Promise.all([
        api.get(`/github/repos/${seg(owner)}/${seg(repo)}/inspect`, { signal: controller.signal }),
        ascConfigured === null ? api.get('/settings', { signal: controller.signal }).catch(() => null) : null,
      ]);
      if (settings) ascConfigured = Boolean(settings.appStoreConnect);
      if (inspecting !== controller) return;
      state.inspection = inspection;
      state.picking = null;
      state.manualFor = undefined;
      if (state.step !== 'app') return;
      // The repository builds one app, found in App Store Connect and not added yet: nothing to choose.
      const ready = inspection.apps.filter((app) => app.appStoreConnect && !app.appStoreConnect.registered);
      state.manual = null;
      if (inspection.apps.length === 1 && ready.length === 1) {
        state.app = ready[0];
        state.autoMatched = true;
        go('review');
        return;
      }
      // Several apps: the only matched one is pre-selected, and Next takes it.
      state.app = ready.length === 1 ? ready[0] : null;
      render();
    } catch (error) {
      if (error.code === 'aborted' || inspecting !== controller || state.step !== 'app') return;
      const retry = button('Try Again', { class: 'button button-secondary button-small', onClick: () => render() });
      let message;
      if (error.code === 'no_project_found') {
        message = [`Hangar found no Xcode project or XcodeGen project.yml in ${state.repo.fullName}.`];
      } else if (error.code === 'github_unauthorized') {
        message = ['GitHub refused the token. Set a new one in ', settingsLink(), '.'];
      } else if (error.code === 'repository_not_found') {
        message = state.repo.pasted
          ? ['The GitHub token can’t read this repository. Check the URL, or give the token access in ', settingsLink(), '.']
          : [error.message];
      } else {
        message = [error.message];
      }
      state.manualFor = null;
      const manual = manualForm(null);
      replaceChildren(content,
        h('div', { class: 'add-app-callout warning', role: 'alert' }, message, ' ', retry),
        manual.element);
      handle.setActions([backToRepo, { label: 'Next', kind: 'primary', onClick: () => { manual.submit(); return false; } }]);
    } finally {
      if (inspecting === controller) inspecting = null;
    }
  }

  function checkAgain() {
    state.inspection = null;
    render();
  }

  function detectedCard(app) {
    const asc = app.appStoreConnect;
    const platforms = app.platforms.map((platform) => PLATFORM_NAMES[platform] ?? platform).join(' · ');
    const text = (name, status) => h('span', { class: 'detected-text' },
      h('span', { class: 'detected-name' }, name),
      h('span', { class: 'detected-detail' }, [app.bundleIDs.join(', '), platforms].filter(Boolean).join(' — ')),
      status);
    if (asc) {
      return h('button', {
        type: 'button',
        class: 'detected-item',
        disabled: asc.registered,
        'aria-pressed': String(state.app === app),
        onClick: () => {
          state.app = app;
          state.manual = null;
          state.autoMatched = false;
          go('review');
        },
      },
      detectedIcon(app),
      text(asc.name, asc.registered
        ? h('span', { class: 'detected-status' }, 'Already in Hangar')
        : h('span', { class: 'detected-status found' }, checkBadge('found-check'), 'In App Store Connect')));
    }
    const small = 'button button-secondary button-small';
    let status;
    let actions;
    let open; // what picking the card does
    if (state.inspection.appStoreConnectUnavailable) {
      status = `Couldn’t check App Store Connect: ${state.inspection.appStoreConnectError ?? 'it did not answer'}.`;
      actions = [button('Try Again', { class: small, onClick: checkAgain })];
      open = () => { state.picking = null; state.manualFor = app; renderAppStep(); };
    } else if (ascConfigured === false) {
      status = 'App Store Connect is not connected: type its app ID.';
      actions = [];
      open = () => { state.picking = null; state.manualFor = app; renderAppStep(); };
    } else {
      status = 'No App Store Connect app has its bundle ID. Hangar needs the App Store Connect app to number builds.';
      open = () => { state.picking = app; state.manualFor = undefined; renderAppStep(); };
      actions = [
        button('Pick from App Store Connect', { class: 'button button-primary button-small', onClick: open }),
        h('a', { href: ASC_APPS_URL, target: '_blank', rel: 'noopener noreferrer', class: small }, 'Create in App Store Connect'),
        button('Check Again', { class: small, onClick: checkAgain }),
      ];
    }
    return h('div', { class: ['detected-item', 'unmatched', (state.picking === app || state.manualFor === app) && 'open'] },
      h('button', { type: 'button', class: 'detected-pick', 'aria-expanded': String(state.picking === app || state.manualFor === app), onClick: open },
        detectedIcon(app),
        text(app.name, h('span', { class: 'detected-status' }, status))),
      actions.length ? h('span', { class: 'detected-actions' }, actions) : null);
  }

  /** The team's App Store Connect apps to pick `detected` from, closest name first; typing the ID is the last resort. */
  function ascPicker(detected) {
    const panel = h('div', { class: 'asc-pick-panel' });
    const search = h('input', {
      class: 'input asc-search', type: 'search', placeholder: 'Search App Store Connect', autocomplete: 'off',
      spellcheck: 'false', 'aria-label': 'Search App Store Connect apps',
    });
    const list = h('ul', { class: 'pick-list', 'aria-label': 'App Store Connect apps' });
    const typeID = h('button', {
      type: 'button', class: 'link-button',
      onClick: () => { state.picking = null; state.manualFor = detected; renderAppStep(); },
    }, 'It’s not listed: type the app ID');

    function renderList() {
      const query = search.value.trim().toLowerCase();
      const ranked = rankAppStoreConnectApps(ascApps, detected).filter((app) => !query
        || app.name.toLowerCase().includes(query) || app.bundleID.toLowerCase().includes(query) || app.id.includes(query));
      replaceChildren(list, ranked.length === 0
        ? h('li', { class: 'pick-empty' }, 'No matching apps.')
        : ranked.map((app) => h('li', null, h('button', {
          type: 'button',
          class: 'pick-item',
          disabled: app.registered,
          onClick: () => {
            state.app = { ...detected, name: app.name, appStoreConnect: app };
            state.manual = null;
            go('review');
          },
        },
        appIcon(app, 'small'),
        h('span', { class: 'pick-item-text' },
          h('span', { class: 'pick-item-name' }, app.name),
          h('span', { class: 'pick-item-detail' }, `${app.bundleID} · ${app.id}`)),
        app.registered ? h('span', { class: 'pick-badge' }, 'Added') : null))));
    }

    if (ascApps) {
      search.addEventListener('input', renderList);
      listKeys(search, list);
      renderList();
      replaceChildren(panel, search, list, h('div', { class: 'add-app-links' }, typeID));
    } else {
      replaceChildren(panel, h('div', { class: 'picker-status' }, spinner('Loading App Store Connect apps')), typeID);
      api.get('/asc/apps').then((list) => {
        ascApps = list ?? [];
        if (state.picking === detected && state.step === 'app') renderAppStep();
      }, (error) => {
        if (!panel.isConnected) return;
        replaceChildren(panel,
          h('div', { class: 'add-app-callout warning' }, `App Store Connect apps could not be listed: ${error.message}`),
          typeID);
      });
    }
    return panel;
  }

  /** The icon found in the repository (served by Hangar), else App Store Connect's, else a monogram. */
  function detectedIcon(app) {
    const fallback = () => appIcon({ name: app.appStoreConnect?.name ?? app.name, iconURL: app.appStoreConnect?.iconURL }, 'medium');
    if (app.icon?.kind !== 'appiconset' || !state.inspection?.commit) return fallback();
    // encodeURIComponent, not URLSearchParams: the server reads `+` as a plus, not a space.
    const query = `commit=${encodeURIComponent(state.inspection.commit)}&path=${encodeURIComponent(app.icon.path)}`;
    const image = h('img', {
      class: 'app-icon app-icon-medium', alt: '', loading: 'lazy',
      src: `/api/v1/github/repos/${seg(state.repo.owner)}/${seg(state.repo.repo)}/icon?${query}`,
    });
    image.addEventListener('error', () => image.replaceWith(fallback()), { once: true });
    return image;
  }

  /** Name and App Store Connect ID typed by hand, for `detected` (its bundle IDs and schemes carry forward) or none. */
  function manualForm(detected) {
    const apps = state.inspection?.apps ?? [];
    const defaultName = detected?.name ?? (apps.length === 1 ? apps[0].name : state.repo.repo);
    const name = h('input', {
      ...textAttrs, autocapitalize: 'words', placeholder: 'Legilo',
      value: state.manual && state.manual.for === detected ? state.manual.name : defaultName,
    });
    const ascID = h('input', {
      ...textAttrs, class: 'input mono', inputmode: 'numeric', placeholder: '1234567890',
      value: state.manual && state.manual.for === detected ? state.manual.ascID : '',
    });
    for (const input of [name, ascID]) input.addEventListener('input', () => input.removeAttribute('aria-invalid'));
    const submit = () => {
      const invalid = (input, message) => {
        input.setAttribute('aria-invalid', 'true');
        input.focus();
        handle.setError(message);
      };
      if (!name.value.trim()) return invalid(name, 'Enter the app’s name.');
      if (!/^\d+$/.test(ascID.value.trim())) {
        return invalid(ascID, 'Enter the App Store Connect app ID: the number under App Information.');
      }
      state.manual = { name: name.value.trim(), ascID: ascID.value.trim(), for: detected };
      state.app = detected ? { ...detected, name: state.manual.name, appStoreConnect: null } : null;
      go('review');
      return undefined;
    };
    for (const input of [name, ascID]) {
      input.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' && !event.isComposing) {
          event.preventDefault();
          submit();
        }
      });
    }
    const element = h('div', { class: 'form add-app-manual' },
      field({ label: 'Name', control: name }),
      field({ label: 'App Store Connect app ID', hint: 'The Apple ID shown under App Information.', control: ascID }));
    return { element, submit, focus: () => (name.value ? ascID : name).focus() };
  }

  // MARK: Step 3: review

  function renderReviewStep() {
    const app = state.app;
    const asc = app?.appStoreConnect;
    const name = asc?.name ?? state.manual?.name ?? app?.name ?? '';
    const ascID = asc?.id ?? state.manual?.ascID ?? '';
    // The repository's bundle ID picks the schemes to build; App Store Connect's is shown when there is none.
    const bundleID = app?.bundleIDs?.[0] ?? asc?.bundleID ?? null;
    const mismatch = Boolean(asc && app?.bundleIDs?.length && !app.bundleIDs.includes(asc.bundleID));
    const repoURL = state.repo.htmlURL ?? `https://github.com/${state.repo.fullName}`;
    const hasWorkflowFile = Boolean(state.inspection?.hasWorkflowFile);
    const row = (label, value, mono = false) => h('div', { class: 'review-row' },
      h('dt', null, label), h('dd', { class: mono ? 'mono' : null }, value));
    replaceChildren(content,
      h('div', { class: 'review-card' },
        h('div', { class: 'review-head' },
          app ? detectedIcon(app) : appIcon({ name }, 'medium'),
          h('div', null,
            h('p', { class: 'review-name' }, name),
            app?.platforms?.length
              ? h('p', { class: 'secondary' }, app.platforms.map((platform) => PLATFORM_NAMES[platform] ?? platform).join(' · '))
              : null)),
        h('dl', { class: 'review-rows' },
          row(mismatch ? 'Bundle ID (repository)' : 'Bundle ID', bundleID ?? '—', true),
          mismatch ? row('Bundle ID (App Store Connect)', asc.bundleID, true) : null,
          row('App Store Connect ID', ascID, true),
          row('Repository', state.repo.fullName))),
      mismatch
        ? h('div', { class: 'add-app-callout warning', role: 'note' },
          `The App Store Connect app’s bundle ID is ${asc.bundleID} — the repository builds ${app.bundleIDs.join(', ')}. Builds upload to the App Store Connect app only if they match.`)
        : null,
      hasWorkflowFile
        ? h('p', { class: 'add-app-next' }, 'Builds use the repository’s .hangar.yml.')
        : h('p', { class: 'add-app-next' }, 'Next, Hangar fills in the workflow from what it found in the repository.'));
    handle.setActions([
      { label: 'Back', kind: 'secondary', onClick: () => { go('app'); return false; } },
      {
        label: hasWorkflowFile ? 'Add App' : 'Add App and Set Up Workflow',
        kind: 'primary',
        onClick: async () => {
          const request = { name, repoURL, appStoreConnectAppID: ascID };
          if (isHTTPS(asc?.iconURL)) request.iconURL = asc.iconURL;
          const created = await api.post('/apps', request);
          if (!created.iconURL) expectIcon(created.id);
          toast(`Added ${created.name}`, 'success');
          state.repo = null; // nothing left to lose: close without asking
          onAdded?.(created, { hasWorkflowFile, bundleID });
        },
      },
    ]);
    sheetElement.querySelector('.sheet-actions .button-primary')?.focus();
  }

  // `/` jumps to the search field, as on GitHub.
  sheetElement.addEventListener('keydown', (event) => {
    if (event.key !== '/' || event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement) return;
    const search = sheetElement.querySelector('input[type="search"]');
    if (!search) return;
    event.preventDefault();
    search.focus();
    search.select();
  });

  render();
  return handle;
}

function lockBadge() {
  return h('span', { class: 'pick-lock', title: 'Private', 'aria-label': 'Private' },
    svg('svg', { viewBox: '0 0 16 16', 'aria-hidden': 'true' },
      svg('rect', { x: '3.5', y: '7', width: '9', height: '7', rx: '1.5' }),
      svg('path', { d: 'M5.5 7V5a2.5 2.5 0 0 1 5 0v2' })));
}

/**
 * Arrow keys move between the enabled buttons of `list` (Home and End to the ends); from `search`, ArrowDown goes
 * to the first one and Enter picks it. Enter or Space on a button picks it, as buttons do.
 */
function listKeys(search, list) {
  if (!list) return;
  // Only this list's own items: a picker nested in a card has a list (and a handler) of its own.
  const items = () => [...list.querySelectorAll(
    'button.pick-item:not(:disabled), button.detected-item:not(:disabled), button.detected-pick')]
    .filter((item) => item.closest('ul') === list);
  search?.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      items()[0]?.focus();
    } else if (event.key === 'Enter' && !event.isComposing) {
      event.preventDefault();
      items()[0]?.click();
    }
  });
  list.addEventListener('keydown', (event) => {
    const all = items();
    const index = all.indexOf(document.activeElement);
    if (index < 0) return;
    let target = null;
    if (event.key === 'ArrowDown') target = all[index + 1];
    else if (event.key === 'ArrowUp') target = index === 0 && search ? search : all[index - 1];
    else if (event.key === 'Home') target = all[0];
    else if (event.key === 'End') target = all.at(-1);
    else return;
    event.preventDefault();
    event.stopPropagation(); // an outer list must not move focus again
    target?.focus();
    target?.scrollIntoView?.({ block: 'nearest' });
  });
}

// The Add App sheet: pick the GitHub repository, then the app Hangar found in it (matched to App Store Connect by
// bundle ID), then review and add. Nothing is typed in the common case.

import { api, ApiError, seg } from '../api.js';
import {
  button, confirm, field, h, relativeTime, replaceChildren, sheet, spinner, svg, toast,
} from '../ui.js';
import { filterRepositories, parseRepositoryURL, rankRepositories } from '../repo-ranking.js';
import { appIcon, expectIcon, isHTTPS } from './apps.js';

const PLATFORM_NAMES = { ios: 'iOS', macos: 'macOS', visionos: 'visionOS', tvos: 'tvOS', watchos: 'watchOS' };
const ASC_APPS_URL = 'https://appstoreconnect.apple.com/apps';
const STEPS = [['repo', 'Repository'], ['app', 'App'], ['review', 'Review']];

const textAttrs = { class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off' };

/** Opens the sheet; `onAdded(app)` runs after the server created the app. */
export function openAddAppSheet({ onAdded } = {}) {
  const state = {
    step: 'repo',
    repo: null, // { owner, repo, fullName, htmlURL, isPrivate }
    inspection: null, // RepositoryInspection of `repo`
    app: null, // the DetectedApp picked
    manual: null, // { name, ascID } typed by hand instead
  };
  let repos = null; // GitHubRepo[], loaded once
  let reposError = null;
  let ascConfigured = null;
  let inspecting = null; // the AbortController of the running inspection

  const steps = h('ol', { class: 'add-app-steps' });
  const content = h('div', { class: 'add-app-content' });
  const handle = sheet({
    title: 'Add App',
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
    replaceChildren(steps, STEPS.map(([id, label], index) => h('li', {
      class: ['add-app-step', id === state.step && 'current'],
      'aria-current': id === state.step ? 'step' : null,
    }, h('span', { class: 'add-app-step-number', 'aria-hidden': 'true' }, String(index + 1)), label)));
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
      pickRepo({ ...parsed, htmlURL: `https://github.com/${parsed.fullName}`, isPrivate: false });
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
      const notConfigured = reposError instanceof ApiError && reposError.code === 'github_not_configured';
      replaceChildren(content,
        h('div', { class: 'add-app-callout' },
          notConfigured
            ? ['Add a GitHub token in ', h('a', { href: '/settings', 'data-link': true }, 'Settings'),
              ' to pick from your repositories, or paste the repository’s URL.']
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
          h('span', { class: 'secondary' }, `${owner}/`), name,
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
    if (state.repo?.fullName !== repo.fullName) {
      state.inspection = null;
      state.app = null;
      state.manual = null;
    }
    state.repo = repo;
    go('app');
  }

  // MARK: Step 2: the app in the repository

  function renderAppStep() {
    const back = { label: 'Back', kind: 'secondary', onClick: () => { go('repo'); return false; } };
    if (!state.inspection) {
      replaceChildren(content, h('div', { class: 'picker-status' }, spinner(`Reading ${state.repo.fullName}`),
        h('p', { class: 'picker-status-label' }, `Reading ${state.repo.fullName}…`)));
      handle.setActions([back]);
      inspect();
      return;
    }
    const { apps } = state.inspection;
    const manual = manualForm();
    const cards = apps.map((app) => detectedCard(app));
    const showManual = h('button', { type: 'button', class: 'link-button' }, 'Enter the App Store Connect app ID by hand');
    manual.element.hidden = !state.manual;
    showManual.hidden = Boolean(state.manual);
    showManual.addEventListener('click', () => {
      manual.element.hidden = false;
      showManual.hidden = true;
      manual.focus();
      handle.setActions([back, next]);
    });
    const next = { label: 'Next', kind: 'primary', onClick: () => { manual.submit(); return false; } };

    replaceChildren(content,
      apps.length === 0
        ? h('div', { class: 'add-app-callout' }, `Hangar found no app target in ${state.repo.fullName}. Enter the app by hand.`)
        : h('ul', { class: 'detected-list', 'aria-label': 'Apps in the repository' }, cards.map((card) => h('li', null, card))),
      ascConfigured === false
        ? h('div', { class: 'add-app-callout' }, 'Add your App Store Connect key in ',
          h('a', { href: '/settings', 'data-link': true }, 'Settings'), ' to find these apps in App Store Connect.')
        : null,
      h('div', { class: 'add-app-links' }, showManual),
      manual.element);
    handle.setActions(state.manual ? [back, next] : [back]);
    listKeys(null, content.querySelector('.detected-list'));
    (content.querySelector('.detected-item:not(:disabled)') ?? (state.manual ? null : showManual))?.focus();
    if (state.manual) manual.focus();
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
      if (state.step === 'app') render();
    } catch (error) {
      if (error.code === 'aborted' || inspecting !== controller || state.step !== 'app') return;
      const retry = button('Try Again', { onClick: () => render() });
      const message = error.code === 'no_project_found'
        ? `Hangar found no Xcode project or XcodeGen project.yml in ${state.repo.fullName}.`
        : error.message;
      const manual = manualForm();
      manual.element.hidden = false;
      replaceChildren(content,
        h('div', { class: 'add-app-callout warning', role: 'alert' }, message, ' ', retry),
        manual.element);
      handle.setActions([
        { label: 'Back', kind: 'secondary', onClick: () => { go('repo'); return false; } },
        { label: 'Next', kind: 'primary', onClick: () => { manual.submit(); return false; } },
      ]);
    } finally {
      if (inspecting === controller) inspecting = null;
    }
  }

  function detectedCard(app) {
    const asc = app.appStoreConnect;
    const platforms = app.platforms.map((platform) => PLATFORM_NAMES[platform] ?? platform).join(' · ');
    const details = h('span', { class: 'detected-detail' },
      [app.bundleIDs.join(', '), platforms].filter(Boolean).join(' — '));
    const icon = detectedIcon(app);
    if (asc) {
      return h('button', {
        type: 'button',
        class: 'detected-item',
        disabled: asc.registered,
        'aria-pressed': String(state.app === app),
        onClick: () => {
          state.app = app;
          state.manual = null;
          go('review');
        },
      },
      icon,
      h('span', { class: 'detected-text' },
        h('span', { class: 'detected-name' }, asc.name),
        details,
        asc.registered
          ? h('span', { class: 'detected-status' }, 'Already in Hangar')
          : h('span', { class: 'detected-status found' }, 'Found in App Store Connect ✓')));
    }
    // Not in App Store Connect: it cannot be picked until it is, or its ID is typed by hand.
    return h('div', { class: 'detected-item unmatched' },
      icon,
      h('span', { class: 'detected-text' },
        h('span', { class: 'detected-name' }, app.name),
        details,
        h('span', { class: 'detected-status' },
          ascConfigured === false
            ? 'App Store Connect is not connected.'
            : 'Not in App Store Connect — Hangar needs the App Store Connect app to number builds.'),
        ascConfigured === false ? null : h('span', { class: 'detected-actions' },
          h('a', { href: ASC_APPS_URL, target: '_blank', rel: 'noopener noreferrer', class: 'button button-secondary button-small' },
            'Create in App Store Connect'),
          button('Check Again', {
            class: 'button button-secondary button-small',
            onClick: () => {
              state.inspection = null;
              render();
            },
          }))));
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

  function manualForm() {
    const name = h('input', {
      ...textAttrs, autocapitalize: 'words', placeholder: 'Legilo',
      value: state.manual?.name ?? state.inspection?.apps?.[0]?.name ?? state.repo.repo,
    });
    const ascID = h('input', {
      ...textAttrs, class: 'input mono', inputmode: 'numeric', placeholder: '1234567890', value: state.manual?.ascID ?? '',
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
      state.manual = { name: name.value.trim(), ascID: ascID.value.trim() };
      state.app = null;
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
    const name = asc?.name ?? state.manual?.name ?? '';
    const ascID = asc?.id ?? state.manual?.ascID ?? '';
    const repoURL = state.repo.htmlURL ?? `https://github.com/${state.repo.fullName}`;
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
          row('Bundle ID', asc?.bundleID ?? app?.bundleIDs?.[0] ?? '—', true),
          row('App Store Connect ID', ascID, true),
          row('Repository', state.repo.fullName))),
      h('p', { class: 'section-footer' }, 'Next, Hangar sets up the workflow from what it found in the repository.'));
    handle.setActions([
      { label: 'Back', kind: 'secondary', onClick: () => { go('app'); return false; } },
      {
        label: 'Add App',
        kind: 'primary',
        onClick: async () => {
          const request = { name, repoURL, appStoreConnectAppID: ascID };
          if (isHTTPS(asc?.iconURL)) request.iconURL = asc.iconURL;
          const created = await api.post('/apps', request);
          if (!created.iconURL) expectIcon(created.id);
          toast(`Added ${created.name}`, 'success');
          state.repo = null; // nothing left to lose: close without asking
          onAdded?.(created);
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
  const items = () => [...list.querySelectorAll('button.pick-item:not(:disabled), button.detected-item:not(:disabled)')];
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
    target?.focus();
    target?.scrollIntoView?.({ block: 'nearest' });
  });
}

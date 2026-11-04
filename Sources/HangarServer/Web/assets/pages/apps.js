// The Apps page: a card per app with its latest build and a Deploy button, and the Add App sheet.

import { api, ApiError, events, seg } from '../api.js';
import { navigate } from '../router.js';
import {
  button, emptyState, field, h, page, relativeTime, replaceChildren, sheet, spinner, statusBadge, toast,
} from '../ui.js';
import { openDeploySheet } from './deploy.js';

// MARK: App icon

const MONOGRAM_TONES = 8;

/** A stable tone (0–7) for a name: FNV-1a over its characters. */
function toneFor(name) {
  let hash = 0x811c9dc5;
  for (const character of name.toLowerCase()) {
    hash ^= character.codePointAt(0);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash % MONOGRAM_TONES;
}

function monogram(app, size) {
  const letter = [...(app.name ?? '')].find((character) => /[\p{L}\p{N}]/u.test(character)) ?? '?';
  return h('span', { class: ['app-icon', `app-icon-${size}`, 'monogram', `monogram-${toneFor(app.name ?? '')}`], 'aria-hidden': 'true' },
    letter.toLocaleUpperCase());
}

function isHTTPS(url) {
  return typeof url === 'string' && /^https:\/\//i.test(url);
}

/**
 * The app's icon: its `iconURL` image (https only, which the CSP allows) or a rounded-square monogram coloured
 * from the name. `size` is `large` (detail page), `medium` (cards) or `small` (lists).
 */
export function appIcon(app, size = 'medium') {
  if (!isHTTPS(app.iconURL)) return monogram(app, size);
  const image = h('img', {
    class: ['app-icon', `app-icon-${size}`], src: app.iconURL, alt: '', loading: 'lazy', referrerpolicy: 'no-referrer',
  });
  image.addEventListener('error', () => image.replaceWith(monogram(app, size)), { once: true });
  return image;
}

// MARK: Icon resolved after adding

/** How long after adding an app without an icon its page looks again for the one the server resolves. */
const ICON_RECHECK_MS = 3000;
const awaitingIcon = new Set(); // ids of apps added here without an icon, not yet looked at again

/**
 * Once, ~3 s after this page shows, calls `recheck()` if any of `apps` was just added without an icon: the server
 * resolves one in the background. Cancelled when the page is left.
 */
export function recheckIconSoon(apps, context, recheck) {
  const pending = apps.filter((app) => awaitingIcon.has(app.id));
  if (pending.length === 0) return;
  const timer = setTimeout(() => {
    pending.forEach((app) => awaitingIcon.delete(app.id));
    Promise.resolve(recheck()).catch(() => {});
  }, ICON_RECHECK_MS);
  context.onCleanup(() => clearTimeout(timer));
}

// MARK: Apps page

/** The `/` route. */
export async function appsPage(params, context) {
  const grid = h('div', { class: 'grid app-grid' });
  const content = h('div', null, grid);
  let apps = [];
  const latest = new Map(); // app id → newest Build

  async function load() {
    apps = await api.get('/apps', { signal: context.signal });
    apps.sort((a, b) => a.name.localeCompare(b.name));
    const results = await Promise.allSettled(
      apps.map((app) => api.get(`/builds?app=${seg(app.slug)}&limit=1`, { signal: context.signal })));
    latest.clear();
    results.forEach((result, index) => {
      if (result.status === 'fulfilled' && result.value?.[0]) latest.set(apps[index].id, result.value[0]);
    });
  }

  function render() {
    if (apps.length === 0) {
      replaceChildren(content, emptyState({
        icon: h('span', { class: 'empty-plus' }, '+'),
        title: 'No Apps Yet',
        message: 'Add an app from App Store Connect and its GitHub repository to start building.',
        action: button('Add App', { kind: 'primary', onClick: addApp }),
      }));
      return;
    }
    replaceChildren(grid,
      apps.map((app) => appCard(app, latest.get(app.id))),
      h('button', { type: 'button', class: 'card app-card add-card', onClick: addApp },
        h('span', { class: 'add-card-plus', 'aria-hidden': 'true' }, '+'),
        h('span', { class: 'add-card-label' }, 'Add App')));
    replaceChildren(content, grid);
  }

  function addApp() {
    openAddAppSheet({ onAdded: (app) => navigate(`/apps/${encodeURIComponent(app.slug)}`) });
  }

  await load();
  render();
  recheckIconSoon(apps, context, () => load().then(render));

  context.onCleanup(events((event) => {
    if (event.type !== 'build' || !event.build) return;
    const build = event.build;
    if (!apps.some((app) => app.id === build.appID)) return;
    const current = latest.get(build.appID);
    if (!current || current.id === build.id || new Date(build.createdAt) >= new Date(current.createdAt)) {
      latest.set(build.appID, build);
      render();
    }
  }, {
    onReconnect: () => load().then(render, () => {}),
  }));

  return page({ title: 'Apps' }, content);
}

function appCard(app, build) {
  const href = `/apps/${encodeURIComponent(app.slug)}`;
  return h('article', { class: 'card app-card' },
    h('div', { class: 'app-card-top' },
      appIcon(app, 'medium'),
      button('Deploy', {
        kind: 'secondary',
        class: 'button button-secondary button-small app-card-deploy',
        'aria-label': `Deploy ${app.name}`,
        onClick: () => openDeploySheet(app),
      })),
    h('h2', { class: 'app-card-name' },
      // The link covers the whole card (see .app-card-link::after); the Deploy button sits above it.
      h('a', { href, 'data-link': true, class: 'app-card-link' }, app.name)),
    build
      ? h('div', { class: 'app-card-build' },
        h('span', { class: 'app-card-number' }, `Build ${build.buildNumber}`),
        statusBadge(build.status),
        h('span', { class: 'app-card-time' }, relativeTime(build.createdAt)))
      : h('p', { class: 'app-card-build secondary' }, 'No builds yet'));
}

// MARK: Add App sheet

const REPOSITORY_PATTERN = /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+?(\.git)?\/?$/;

/** Opens the Add App sheet; `onAdded(app)` runs after the server created it. */
export function openAddAppSheet({ onAdded } = {}) {
  const textAttrs = { class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off' };
  const clearInvalid = (event) => event.target.removeAttribute('aria-invalid');
  const name = h('input', { ...textAttrs, autocapitalize: 'words', placeholder: 'Legilo', onInput: clearInvalid });
  const repo = h('input', {
    ...textAttrs, type: 'url', inputmode: 'url', placeholder: 'https://github.com/owner/repo', onInput: clearInvalid,
  });
  const ascID = h('input', {
    ...textAttrs, class: 'input mono', inputmode: 'numeric', placeholder: '1234567890', onInput: clearInvalid,
  });
  const icon = h('input', {
    ...textAttrs, type: 'url', inputmode: 'url', placeholder: 'https://… (optional)', onInput: clearInvalid,
  });
  const picker = h('div', { class: 'asc-picker' }, h('div', { class: 'asc-picker-status' }, spinner('Loading apps')));

  const handle = sheet({
    title: 'Add App',
    submitOnEnter: true,
    body: h('div', { class: 'form' },
      picker,
      field({ label: 'Name', control: name }),
      field({ label: 'App Store Connect app ID', hint: 'The Apple ID shown under App Information.', control: ascID }),
      field({ label: 'Repository', hint: 'The GitHub repository the builds check out.', control: repo }),
      field({ label: 'Icon URL', hint: 'An https image; without one the app gets a monogram.', control: icon })),
    actions: [
      { label: 'Cancel', kind: 'cancel' },
      {
        label: 'Add',
        kind: 'primary',
        onClick: async () => {
          const request = {
            name: name.value.trim(),
            repoURL: repo.value.trim(),
            appStoreConnectAppID: ascID.value.trim(),
          };
          const iconURL = icon.value.trim();
          if (iconURL) request.iconURL = iconURL;
          const invalid = (input, message) => {
            input.setAttribute('aria-invalid', 'true');
            input.focus();
            throw new Error(message);
          };
          if (!request.name) invalid(name, 'Enter the app’s name.');
          if (!request.appStoreConnectAppID) invalid(ascID, 'Enter the App Store Connect app ID, or pick the app above.');
          if (!REPOSITORY_PATTERN.test(request.repoURL)) {
            invalid(repo, 'Enter the repository as https://github.com/<owner>/<repo>.');
          }
          if (iconURL && !/^https:\/\/\S+$/i.test(iconURL)) invalid(icon, 'The icon URL must start with https://.');
          const app = await api.post('/apps', request);
          if (!app.iconURL) awaitingIcon.add(app.id);
          toast(`Added ${app.name}`, 'success');
          onAdded?.(app);
        },
      },
    ],
  });

  let autoIcon = ''; // the icon URL the last pick filled in; a URL typed over it is the user's and stays
  loadPicker(picker, (app) => {
    name.value = app.name;
    ascID.value = app.id;
    if (icon.value.trim() === '' || icon.value === autoIcon) {
      autoIcon = isHTTPS(app.iconURL) ? app.iconURL : '';
      icon.value = autoIcon;
    }
    name.removeAttribute('aria-invalid');
    ascID.removeAttribute('aria-invalid');
    icon.removeAttribute('aria-invalid');
    repo.focus();
  }).catch(() => {});
  return handle;
}

/** Fills `picker` with the team's App Store Connect apps, or explains why they cannot be listed. */
async function loadPicker(picker, onPick) {
  const settingsLink = () => h('a', { href: '/settings', 'data-link': true }, 'Settings');
  const note = (...children) => replaceChildren(picker, h('p', { class: 'asc-picker-note' }, children));

  let configured = true;
  try {
    const settings = await api.get('/settings');
    configured = Boolean(settings?.appStoreConnect);
  } catch {
    // Unknown: ask for the apps anyway; a missing key answers 409.
  }
  if (!configured) {
    note('Add your App Store Connect key in ', settingsLink(), ' to pick from your apps, or type the app ID below.');
    return;
  }
  let ascApps;
  try {
    ascApps = await api.get('/asc/apps');
  } catch (error) {
    if (error instanceof ApiError && error.code === 'asc_not_configured') {
      note('Add your App Store Connect key in ', settingsLink(), ' to pick from your apps, or type the app ID below.');
    } else {
      note(`Your App Store Connect apps could not be listed: ${error.message} Type the app ID below.`);
    }
    return;
  }
  if (!picker.isConnected) return;
  if (ascApps.length === 0) {
    note('App Store Connect lists no apps for this key. Type the app ID below.');
    return;
  }

  const search = h('input', {
    class: 'input', type: 'search', placeholder: 'Search your apps', autocomplete: 'off', spellcheck: 'false',
    'aria-label': 'Search App Store Connect apps',
  });
  const list = h('ul', { class: 'asc-list', 'aria-label': 'App Store Connect apps' });
  let selected = null;

  function renderList() {
    const query = search.value.trim().toLowerCase();
    const matches = ascApps.filter((app) => !query
      || app.name.toLowerCase().includes(query) || app.bundleID.toLowerCase().includes(query) || app.id.includes(query));
    replaceChildren(list, matches.length === 0
      ? h('li', { class: 'asc-empty' }, 'No matching apps.')
      : matches.map((app) => h('li', null,
        h('button', {
          type: 'button',
          class: 'asc-item',
          disabled: app.registered,
          'aria-pressed': String(selected === app.id),
          onClick: () => {
            selected = app.id;
            renderList();
            onPick(app);
          },
        },
        appIcon(app, 'small'),
        h('span', { class: 'asc-item-text' },
          h('span', { class: 'asc-item-name' }, app.name),
          h('span', { class: 'asc-item-detail' }, `${app.bundleID} · ${app.id}`)),
        app.registered ? h('span', { class: 'asc-item-badge' }, 'Added') : null))));
  }

  search.addEventListener('input', renderList);
  renderList();
  replaceChildren(picker,
    h('p', { class: 'field-label' }, 'Pick from App Store Connect'),
    search,
    list);
}

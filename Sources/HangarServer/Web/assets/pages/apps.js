// The Apps page: a card per app with its latest build and a Deploy button; Add App opens pages/add-app.js.

import { api, events, seg } from '../api.js';
import { navigate } from '../router.js';
import {
  button, emptyState, h, page, relativeTime, replaceChildren, statusBadge,
} from '../ui.js';
import { openAddAppSheet } from './add-app.js';
import { openDeploySheet } from './deploy.js';
import { setupIncomplete, setupSkipped } from './setup.js';

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

export function isHTTPS(url) {
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

/** Marks an app just added without an icon, so its page looks again for the one the server resolves. */
export function expectIcon(appID) {
  awaitingIcon.add(appID);
}

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

  let setupLeft = false; // with no apps: setup still has a step to do

  function render() {
    if (apps.length === 0) {
      replaceChildren(content, emptyState({
        icon: h('span', { class: 'empty-plus' }, '+'),
        title: 'No Apps Yet',
        message: setupLeft
          ? 'Finish setting up Hangar first: App Store Connect, GitHub and a Mac to build on.'
          : 'Pick its GitHub repository: Hangar finds the app in it and in App Store Connect.',
        action: setupLeft
          ? h('a', { href: '/setup', 'data-link': true, class: 'button button-primary' }, 'Finish Setup')
          : button('Add App', { kind: 'primary', onClick: addApp }),
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
    // Straight on to the workflow, pre-filled from what Hangar finds in the repository; a repository with its
    // own .hangar.yml keeps building with it, so its app page is shown instead.
    openAddAppSheet({
      onAdded: (app, { hasWorkflowFile, bundleID } = {}) => {
        const base = `/apps/${encodeURIComponent(app.slug)}`;
        const query = new URLSearchParams({ suggest: '1' });
        if (bundleID) query.set('bundleID', bundleID);
        navigate(hasWorkflowFile ? base : `${base}/workflow?${query}`);
      },
    });
  }

  await load();
  if (apps.length === 0) {
    // A new server: the setup page instead of an empty page, unless it was skipped in this tab.
    const status = await api.get('/setup', { signal: context.signal }).catch(() => null);
    setupLeft = Boolean(status && setupIncomplete(status));
    if (setupLeft && !setupSkipped()) {
      navigate('/setup', { replace: true });
      return h('div');
    }
  }
  render();
  if (context.query.get('add') === '1') {
    history.replaceState(null, '', '/');
    addApp();
  }
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

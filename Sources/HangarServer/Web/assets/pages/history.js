// The History page (`/builds`): the latest builds across apps, filtered by app, kept live from the event stream.

import { api, ApiError, events, seg } from '../api.js';
import { emptyState, h, page, relativeTime, replaceChildren, spinner, statusBadge, button } from '../ui.js';
import { appIcon } from './apps.js';
import { buildDuration } from './build.js';
import { openDeploySheet } from './deploy.js';

const LIMIT = 50;
const REFRESH_MS = 60_000;

/** The `/builds` route; `?app=<slug>` filters by app. */
export async function historyPage(params, context) {
  const { signal } = context;
  let apps = await api.get('/apps', { signal });
  apps.sort((a, b) => a.name.localeCompare(b.name));
  let appsByID = new Map(apps.map((app) => [app.id, app]));
  let filter = context.query.get('app') ?? '';
  let builds = null;
  let generation = 0;
  let whenCells = []; // [element, build] of the rendered rows

  const select = h('select', {
    class: 'input select history-filter', id: 'history-app', onChange: () => {
      filter = select.value;
      const url = filter ? `/builds?app=${seg(filter)}` : '/builds';
      history.replaceState(null, '', url);
      load();
    },
  });
  function renderFilter() {
    replaceChildren(select,
      h('option', { value: '' }, 'All apps'),
      apps.map((app) => h('option', { value: app.slug }, app.name)),
      // An unknown slug from the address stays selectable so the page says what it is filtering by.
      filter && !apps.some((app) => app.slug === filter) ? h('option', { value: filter }, filter) : null);
    select.value = filter;
  }

  const list = h('div', { class: 'history' }, h('div', { class: 'list list-loading' }, spinner('Loading builds')));

  function filteredApp() {
    return apps.find((app) => app.slug === filter) ?? null;
  }

  async function load() {
    const current = ++generation;
    builds = null;
    replaceChildren(list, h('div', { class: 'list list-loading' }, spinner('Loading builds')));
    const query = new URLSearchParams({ limit: String(LIMIT) });
    if (filter) query.set('app', filter);
    try {
      const result = await api.get(`/builds?${query}`, { signal });
      if (current !== generation) return;
      builds = result;
      render();
    } catch (error) {
      if (error.code === 'aborted' || current !== generation) return;
      const unknownApp = error instanceof ApiError && error.code === 'app_not_found';
      replaceChildren(list, h('div', { class: 'list inline-error' },
        h('p', { class: 'inline-error-message' }, unknownApp ? `There is no app “${filter}”.` : error.message),
        unknownApp
          ? button('Show All Builds', { kind: 'plain', onClick: () => { select.value = ''; select.dispatchEvent(new Event('change')); } })
          : button('Try Again', { kind: 'plain', onClick: load })));
    }
  }

  function render() {
    if (!builds) return;
    if (builds.length === 0) {
      const app = filteredApp();
      replaceChildren(list, h('div', { class: 'list' }, emptyState({
        title: 'No Builds Yet',
        message: app ? `${app.name} has no builds yet.` : 'Every build you deploy appears here.',
        action: app ? button('Deploy', { kind: 'primary', onClick: () => openDeploySheet(app) }) : null,
      })));
      return;
    }
    const now = new Date();
    whenCells = [];
    replaceChildren(list, h('ul', { class: 'list history-list' }, builds.map((build) => {
      const app = appsByID.get(build.appID);
      const appName = app?.name ?? 'Unknown app';
      return h('li', null,
        h('a', { href: `/builds/${seg(build.id)}`, 'data-link': true, class: 'row history-row' },
          app ? appIcon(app, 'small') : h('span', { class: 'app-icon app-icon-small monogram monogram-0', 'aria-hidden': 'true' }, '?'),
          h('span', { class: 'row-main history-main' },
            h('span', { class: 'row-title history-title' },
              h('span', { class: 'history-app' }, appName),
              h('span', { class: 'history-number' }, `Build ${build.buildNumber}`)),
            h('span', { class: 'row-detail build-ref' },
              `${build.workflow} · ${build.ref} · ${String(build.commit ?? '').slice(0, 7)}`)),
          h('span', { class: 'build-trailing' },
            statusBadge(build.status),
            when(h('span', { class: 'row-detail history-when' }), build, now))));
    })));
  }

  function when(element, build, now) {
    element.textContent = `${relativeTime(build.createdAt, now)} · ${buildDuration(build)}`;
    whenCells.push([element, build]);
    return element;
  }

  /** Moves relative times and running durations on without rebuilding the rows (and losing focus). */
  function refreshTimes() {
    const now = new Date();
    for (const [element, build] of whenCells) {
      element.textContent = `${relativeTime(build.createdAt, now)} · ${buildDuration(build)}`;
    }
  }

  function upsert(build) {
    if (!builds) return;
    const app = filteredApp();
    if (filter && (!app || build.appID !== app.id)) return;
    builds = [build, ...builds.filter((existing) => existing.id !== build.id)]
      .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
      .slice(0, LIMIT);
    render();
  }

  async function reloadApps() {
    try {
      apps = (await api.get('/apps', { signal })).sort((a, b) => a.name.localeCompare(b.name));
      appsByID = new Map(apps.map((app) => [app.id, app]));
      renderFilter();
      render();
    } catch {
      // Keep the list as it is; rows of an unknown app say so.
    }
  }

  context.onCleanup(events((event) => {
    if (event.type !== 'build' || !event.build) return;
    if (!appsByID.has(event.build.appID)) reloadApps();
    upsert(event.build);
  }, { onReconnect: load }));

  const timer = setInterval(refreshTimes, REFRESH_MS);
  context.onCleanup(() => clearInterval(timer));

  renderFilter();
  load();

  return page({
    title: 'History',
    actions: h('div', { class: 'history-filter-field' },
      h('label', { class: 'visually-hidden', for: 'history-app' }, 'App'),
      select),
  }, list);
}

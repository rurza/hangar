// The History page (`/builds`): the latest builds across apps, filtered by app, kept live from the event stream.

import { api, ApiError, events, seg } from '../api.js';
import { withQuery } from '../query.js';
import { emptyState, h, page, replaceChildren, spinner, button } from '../ui.js';
import { buildRow } from './build-rows.js';
import { openDeploySheet } from './deploy.js';

const LIMIT = 50;
const REFRESH_MS = 60_000;

/** The `/builds` route; `?app=<slug>` filters by app. */
export async function historyPage(params, context) {
  const { signal } = context;
  let apps = await api.get('/apps', { signal });
  if (signal.aborted) return null;
  apps.sort((a, b) => a.name.localeCompare(b.name));
  let appsByID = new Map(apps.map((app) => [app.id, app]));
  let filter = context.query.get('app') ?? '';
  let builds = null;
  let generation = 0;
  const rows = new Map(); // build id → row of the rendered list
  let appsRequest = null; // the reloadApps call in flight

  const select = h('select', {
    class: 'popup-button history-filter', id: 'history-app', onChange: () => {
      filter = select.value;
      const url = filter ? `/builds?app=${seg(filter)}` : '/builds';
      history.replaceState(null, '', url);
      load();
    },
  });
  function renderFilter() {
    replaceChildren(select,
      h('option', { value: '' }, 'All Apps'),
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
    try {
      const result = await api.get(withQuery('/builds', { limit: LIMIT, app: filter || null }), { signal });
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

  /**
   * Rebuilds the list (first load, a new filter, renamed apps). Live events go through `upsert`, which changes rows
   * in place so a focused row keeps its focus.
   */
  function render() {
    if (!builds) return;
    rows.clear();
    if (builds.length === 0) {
      const app = filteredApp();
      replaceChildren(list, h('div', { class: 'list' }, emptyState({
        title: 'No Builds Yet',
        message: app ? `${app.name} has no builds yet.` : 'Every build you deploy appears here.',
        action: app ? button('Deploy', { kind: 'primary', onClick: () => openDeploySheet(app) }) : null,
      })));
      return;
    }
    const ul = h('ul', { class: 'list build-list history-list' }, builds.map((build) => rowFor(build).element));
    replaceChildren(list, ul);
  }

  /** A row for `build`, registered in `rows`. */
  function rowFor(build) {
    const row = buildRow(build, { app: (next) => appsByID.get(next.appID) });
    rows.set(build.id, row);
    return row;
  }

  /** Moves relative times and running durations on without rebuilding the rows. */
  function refreshTimes() {
    const now = new Date();
    for (const row of rows.values()) row.tick(now);
  }

  function upsert(build) {
    if (!builds) return;
    const app = filteredApp();
    if (filter && (!app || build.appID !== app.id)) return;
    const index = builds.findIndex((existing) => existing.id === build.id);
    if (index >= 0) {
      // A build's createdAt never changes, so its place in the list stays the same.
      builds[index] = build;
      rows.get(build.id)?.update(build);
      return;
    }
    const at = builds.findIndex((existing) => new Date(existing.createdAt) < new Date(build.createdAt));
    if (at === -1 && builds.length >= LIMIT) return; // Older than everything shown.
    const position = at === -1 ? builds.length : at;
    builds.splice(position, 0, build);
    const ul = list.querySelector('.history-list');
    if (!ul) {
      render(); // The list was empty.
      return;
    }
    ul.insertBefore(rowFor(build).element, ul.children[position] ?? null);
    while (builds.length > LIMIT) {
      const dropped = builds.pop();
      rows.get(dropped.id)?.element.remove();
      rows.delete(dropped.id);
    }
  }

  /** Reloads the apps once at a time, e.g. when a build of an app this page does not know arrives. */
  function reloadApps() {
    appsRequest ??= api.get('/apps', { signal }).then((fresh) => {
      if (signal.aborted) return;
      apps = fresh.sort((a, b) => a.name.localeCompare(b.name));
      appsByID = new Map(apps.map((app) => [app.id, app]));
      renderFilter();
      for (const row of rows.values()) row.update(row.build);
    }, () => {
      // Keep the list as it is; rows of an unknown app say so.
    }).finally(() => { appsRequest = null; });
    return appsRequest;
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

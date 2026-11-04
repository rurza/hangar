// Client-side routing with the History API. Links marked `<a data-link>` navigate without reloading.
//
// A route's `render(params, context)` returns a node, or a promise of one. `params` holds the decoded `:name`
// segments. `context` has `query` (URLSearchParams), `signal` (aborted when the page is left) and `onCleanup(fn)`
// bound to this page. Leaving a page runs its cleanups, so pages register there whatever they must stop: event
// streams, timers, listeners.

import { closeAllSheets, emptyState, h, page, spinner } from './ui.js';
import { ApiError } from './api.js';

const routes = [];
let outlet = null;
let afterRender = null;
let current = null; // { cleanups, controller }

/** Registers a page for a path pattern such as `/apps/:app`. Earlier registrations win. */
export function route(pattern, render) {
  const keys = [];
  const source = pattern === '/'
    ? '^/$'
    : `^${pattern.replace(/\/+$/, '').split('/').map((part) => {
      if (part.startsWith(':')) {
        keys.push(part.slice(1));
        return '([^/]+)';
      }
      return part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }).join('/')}/?$`;
  routes.push({ pattern, regex: new RegExp(source), keys, render });
}

/**
 * Runs `fn` when the current page is left. Call it while the page renders; after an `await` use the
 * `context.onCleanup` the page was given, which stays bound to that page.
 */
export function onCleanup(fn) {
  if (current) current.cleanups.push(fn);
  else fn();
}

/** Goes to `path` (with optional query), adding a history entry unless `replace` is set. */
export function navigate(path, { replace = false } = {}) {
  if (replace) history.replaceState(null, '', path);
  else history.pushState(null, '', path);
  window.scrollTo(0, 0);
  render();
}

/** The current path, without query. */
export function currentPath() {
  return location.pathname;
}

/** Re-renders the current page (the "Try again" of an error state uses it). */
export function reload() {
  render();
}

function match(path) {
  for (const entry of routes) {
    const found = entry.regex.exec(path);
    if (!found) continue;
    const params = {};
    entry.keys.forEach((key, index) => {
      try {
        params[key] = decodeURIComponent(found[index + 1]);
      } catch {
        params[key] = found[index + 1];
      }
    });
    return { entry, params };
  }
  return null;
}

function leave() {
  if (!current) return;
  current.controller.abort();
  for (const fn of current.cleanups.splice(0)) {
    try {
      fn();
    } catch (error) {
      console.error('cleanup failed', error);
    }
  }
  current = null;
}

async function render() {
  leave();
  closeAllSheets();
  const path = location.pathname;
  const state = { cleanups: [], controller: new AbortController() };
  current = state;
  const isCurrent = () => current === state;
  const context = {
    query: new URLSearchParams(location.search),
    signal: state.controller.signal,
    onCleanup: (fn) => {
      if (isCurrent()) state.cleanups.push(fn);
      else fn();
    },
  };

  const found = match(path);
  let loading = null;
  const show = (node) => {
    if (!isCurrent()) return;
    clearTimeout(loading);
    outlet.replaceChildren(...(node instanceof Node ? [node] : []));
    afterRender?.(path);
  };

  if (!found) {
    show(notFound());
    return;
  }
  try {
    const result = found.entry.render(found.params, context);
    if (result instanceof Promise) {
      // Show a spinner only for slow pages, so quick ones do not flash.
      loading = setTimeout(() => {
        if (isCurrent()) outlet.replaceChildren(h('div', { class: 'page-loading' }, spinner()));
      }, 150);
    }
    show(await result);
  } catch (error) {
    if (!isCurrent()) return;
    console.error(error);
    show(failed(error));
  }
}

function notFound() {
  return page({ title: 'Not Found' },
    emptyState({
      title: 'This page does not exist',
      message: 'The link may be out of date.',
      action: h('a', { href: '/', 'data-link': true, class: 'button button-primary' }, 'Go to Apps'),
    }));
}

function failed(error) {
  const message = error instanceof ApiError || error instanceof Error ? error.message : String(error);
  return page({ title: 'Something Went Wrong' },
    emptyState({
      title: 'This page could not be loaded',
      message,
      action: h('button', { type: 'button', class: 'button button-primary', onClick: () => render() }, 'Try Again'),
    }));
}

function onLinkClick(event) {
  if (event.defaultPrevented || event.button !== 0) return;
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const link = event.target.closest?.('a[data-link]');
  if (!link || link.target === '_blank' || link.hasAttribute('download')) return;
  const url = new URL(link.href, location.href);
  if (url.origin !== location.origin) return;
  event.preventDefault();
  if (url.pathname === location.pathname && url.search === location.search) return;
  navigate(url.pathname + url.search + url.hash);
}

/**
 * Starts routing into `outletElement`. `onRendered(path)` runs after each page is in place (the shell uses it to
 * update the tab bar and titles).
 */
export function start(outletElement, { onRendered } = {}) {
  outlet = outletElement;
  afterRender = onRendered;
  document.addEventListener('click', onLinkClick);
  window.addEventListener('popstate', () => render());
  render();
}

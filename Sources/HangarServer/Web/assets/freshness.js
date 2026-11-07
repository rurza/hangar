// Keeps an open page in step with the server. The stylesheets load once, with the page: one that failed to load
// (the server was restarting for an update, say) is loaded again instead of leaving the page unstyled until a
// manual reload. And a page opened before Hangar was updated offers a reload, rather than running old code against
// the new server; it never reloads by itself, as a form may hold unsaved changes.

import { api } from './api.js';
import { h } from './ui.js';

const CHECK_INTERVAL_MS = 120_000;
let loadedVersion = null;
let bar = null;

/** Whether `link`'s stylesheet is missing or empty: it failed to load, or the server answered with nothing. */
function failed(link) {
  if (!link.sheet) return true;
  try {
    return link.sheet.cssRules.length === 0;
  } catch {
    return false; // Unreadable means another origin; Hangar's own are always readable.
  }
}

/** Loads every stylesheet that failed again, under a fresh URL; the old link goes once the new one has loaded. */
function reloadFailedStylesheets() {
  for (const link of document.querySelectorAll('link[rel="stylesheet"]:not([data-retrying])')) {
    if (!failed(link)) continue;
    const url = new URL(link.href);
    url.searchParams.set('retry', String(Date.now()));
    const fresh = h('link', { rel: 'stylesheet', href: url.href });
    link.dataset.retrying = '';
    fresh.addEventListener('load', () => link.remove());
    fresh.addEventListener('error', () => {
      fresh.remove();
      delete link.dataset.retrying;
    });
    link.after(fresh);
  }
}

function showUpdateBar(version) {
  if (bar?.isConnected) return;
  bar = h('div', { class: 'update-bar', role: 'status' },
    h('span', null, `Hangar was updated to ${version}.`),
    h('button', { type: 'button', class: 'button button-primary button-small', onClick: () => location.reload() }, 'Reload'));
  document.body.append(bar);
}

async function checkVersion() {
  let health;
  try {
    health = await api.get('/health');
  } catch {
    return; // The server is away; the next check asks again.
  }
  if (!health?.version) return;
  if (loadedVersion === null) loadedVersion = health.version;
  else if (health.version !== loadedVersion) showUpdateBar(health.version);
}

function check() {
  if (document.visibilityState !== 'visible') return;
  reloadFailedStylesheets();
  checkVersion();
}

/** Starts watching: once the page has loaded, whenever it comes back into view or online, and every two minutes. */
export function watchFreshness() {
  if (document.readyState === 'complete') check();
  else window.addEventListener('load', check, { once: true });
  document.addEventListener('visibilitychange', check);
  window.addEventListener('online', check);
  window.addEventListener('pageshow', check);
  setInterval(check, CHECK_INTERVAL_MS);
}

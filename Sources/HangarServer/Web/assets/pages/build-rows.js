// One row design for a build, shared by History and the app page: (the app's icon,) "Build 88", the workflow,
// branch and commit, and the status with when and how long. Separators start at the text in both lists.

import { seg } from '../api.js';
import { h, relativeTime, replaceChildren, statusBadge } from '../ui.js';
import { appIcon } from './apps.js';
import { buildDuration } from './build.js';

/**
 * A row for `build`. `app(build)` returns the build's app to show its icon and name (History), or is omitted
 * (the app's own page). Returns `{ element, update(build), tick(now) }`: `update` redraws the contents and keeps
 * the link (and its focus); `tick` moves the relative time and running duration on.
 */
export function buildRow(build, { app } = {}) {
  const link = h('a', { href: `/builds/${seg(build.id)}`, 'data-link': true, class: ['row', 'build-row', app && 'with-icon'] });
  const when = h('span', { class: 'row-detail build-when' });
  const row = { element: h('li', null, link), build, update, tick };

  function tick(now = new Date()) {
    when.textContent = `${relativeTime(row.build.createdAt, now)} · ${buildDuration(row.build)}`;
  }

  function update(next) {
    row.build = next;
    const owner = app?.(next);
    replaceChildren(link,
      app
        ? (owner ? appIcon(owner, 'small') : h('span', { class: 'app-icon app-icon-small monogram monogram-0', 'aria-hidden': 'true' }, '?'))
        : null,
      h('span', { class: 'row-main build-main' },
        h('span', { class: 'row-title build-title' },
          app ? h('span', { class: 'build-app' }, owner?.name ?? 'Unknown app') : null,
          h('span', { class: app ? 'build-number-secondary' : 'build-number-primary' }, `Build ${next.buildNumber}`)),
        h('span', { class: 'row-detail build-ref' },
          `${next.workflow} · ${next.ref} · ${String(next.commit ?? '').slice(0, 7)}`)),
      h('span', { class: 'build-trailing' }, statusBadge(next.status), when));
    tick();
  }

  update(build);
  return row;
}

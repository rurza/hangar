// The shell: header with the brand and the tab navigation (a bottom tab bar on phones), the page outlet and
// the route table. Pages live in ./pages/ and are registered below.

import { emptyState, h, page, svg } from './ui.js';
import { route, start } from './router.js';
import { appsPage } from './pages/apps.js';
import { appDetailPage } from './pages/app-detail.js';
import { workflowPage } from './pages/workflow.js';

// MARK: Icons

const ICON_PATHS = {
  apps: [
    ['rect', { x: 4, y: 4, width: 7, height: 7, rx: 2 }],
    ['rect', { x: 13, y: 4, width: 7, height: 7, rx: 2 }],
    ['rect', { x: 4, y: 13, width: 7, height: 7, rx: 2 }],
    ['rect', { x: 13, y: 13, width: 7, height: 7, rx: 2 }],
  ],
  history: [
    ['circle', { cx: 12, cy: 12, r: 8.5 }],
    ['path', { d: 'M12 7.5V12l3 2' }],
  ],
  machines: [
    ['rect', { x: 3, y: 4.5, width: 18, height: 12, rx: 2 }],
    ['path', { d: 'M9 20h6M12 16.5V20' }],
  ],
  settings: [
    ['path', { d: 'M4 7h9M17 7h3M4 17h3M11 17h9' }],
    ['circle', { cx: 15, cy: 7, r: 2 }],
    ['circle', { cx: 9, cy: 17, r: 2 }],
  ],
};

/** An outline icon drawn with the current text colour. */
export function icon(name, className = 'icon') {
  return svg('svg', { class: className, viewBox: '0 0 24 24', 'aria-hidden': 'true', focusable: 'false' },
    ICON_PATHS[name].map(([tag, attrs]) => svg(tag, attrs)));
}

// MARK: Navigation

const TABS = [
  { label: 'Apps', href: '/', icon: 'apps', matches: (path) => path === '/' || path.startsWith('/apps/') },
  { label: 'History', href: '/builds', icon: 'history', matches: (path) => path.startsWith('/builds') },
  { label: 'Machines', href: '/machines', icon: 'machines', matches: (path) => path.startsWith('/machines') },
  { label: 'Settings', href: '/settings', icon: 'settings', matches: (path) => path.startsWith('/settings') },
];

function navigation(className) {
  const links = TABS.map((tab) => h('a', { href: tab.href, 'data-link': true, class: 'tab' },
    icon(tab.icon, 'tab-icon'), h('span', { class: 'tab-label' }, tab.label)));
  const element = h('nav', { class: className, 'aria-label': 'Main' }, links);
  return {
    element,
    update(path) {
      links.forEach((link, index) => {
        if (TABS[index].matches(path)) link.setAttribute('aria-current', 'page');
        else link.removeAttribute('aria-current');
      });
    },
  };
}

// MARK: Shell

function shell(root) {
  const main = h('main', { id: 'main', class: 'content', tabindex: '-1' });
  const compactTitle = h('span', { class: 'topbar-title', 'aria-hidden': 'true' });
  const pills = navigation('pill-nav');
  const tabBar = navigation('tab-bar');
  const header = h('header', { class: 'topbar' },
    h('div', { class: 'topbar-inner' },
      h('a', { href: '/', 'data-link': true, class: 'brand' },
        h('img', { src: '/assets/icon.svg', alt: '', class: 'brand-icon', width: 28, height: 28 }),
        h('span', { class: 'brand-name' }, 'Hangar')),
      compactTitle,
      pills.element));
  const skip = h('button', {
    type: 'button',
    class: 'skip-link',
    onClick: () => main.focus(),
  }, 'Skip to content');

  root.replaceChildren(skip, header, main, tabBar.element);

  // The compact title appears in the header once the page's large title has scrolled under it.
  let observer = null;
  function watchTitle() {
    observer?.disconnect();
    header.classList.remove('condensed');
    const title = main.querySelector('.large-title');
    if (!title || !('IntersectionObserver' in window)) return;
    observer = new IntersectionObserver(([entry]) => {
      header.classList.toggle('condensed', !entry.isIntersecting);
    }, { rootMargin: `-${header.offsetHeight}px 0px 0px 0px` });
    observer.observe(title);
  }

  let first = true;
  return {
    main,
    rendered(path) {
      pills.update(path);
      tabBar.update(path);
      const title = main.querySelector('h1')?.textContent ?? '';
      compactTitle.textContent = title;
      document.title = title ? `${title} – Hangar` : 'Hangar';
      watchTitle();
      // Move focus to the new page for keyboard and screen reader users, but not on the first load.
      if (!first) main.focus({ preventScroll: true });
      first = false;
    },
  };
}

// MARK: Routes

function placeholder(title, iconName, emptyTitle, message, subtitle) {
  return () => page({ title, subtitle },
    emptyState({ icon: icon(iconName, 'empty-icon'), title: emptyTitle, message }));
}

route('/', appsPage);
route('/apps/:app', appDetailPage);
route('/apps/:app/workflow', workflowPage);
route('/builds', placeholder('History', 'history', 'No Builds Yet', 'Every build you deploy appears here.'));
route('/builds/:id', placeholder('Build', 'history', 'Nothing Here Yet', 'The build’s jobs and logs appear here.'));
route('/machines', placeholder('Machines', 'machines', 'No Machines Yet', 'Macs that run your builds appear here.'));
route('/settings', placeholder('Settings', 'settings', 'Nothing to Set Yet', 'App Store Connect, GitHub and global variables appear here.'));

const app = shell(document.getElementById('app'));
start(app.main, { onRendered: (path) => app.rendered(path) });

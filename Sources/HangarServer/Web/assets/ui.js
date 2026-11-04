// Shared UI building blocks. Text always goes in through text nodes, never innerHTML, so data from the API
// cannot become markup.

const SVG_NS = 'http://www.w3.org/2000/svg';

// Attributes set as DOM properties rather than attributes, so they reflect the live state of form controls.
const PROPERTIES = new Set(['value', 'checked', 'indeterminate', 'selected']);

function build(element, attrs, children) {
  for (const [key, value] of Object.entries(attrs ?? {})) {
    if (value === undefined || value === null || value === false) continue;
    if (key.startsWith('on') && typeof value === 'function') {
      element.addEventListener(key.slice(2).toLowerCase(), value);
    } else if (key === 'class' || key === 'className') {
      element.setAttribute('class', Array.isArray(value) ? value.filter(Boolean).join(' ') : value);
    } else if (key === 'dataset') {
      Object.assign(element.dataset, value);
    } else if (key === 'style' && typeof value === 'object') {
      // CSSOM writes are allowed by the CSP; a style="" attribute would not be.
      for (const [name, v] of Object.entries(value)) element.style.setProperty(name, v);
    } else if (key === 'ref' && typeof value === 'function') {
      value(element);
    } else if (PROPERTIES.has(key)) {
      element[key] = value;
    } else {
      element.setAttribute(key, value === true ? '' : String(value));
    }
  }
  append(element, children);
  return element;
}

function append(parent, children) {
  for (const child of children) {
    if (child === null || child === undefined || child === false || child === true) continue;
    if (Array.isArray(child)) append(parent, child);
    else if (child instanceof Node) parent.append(child);
    else parent.append(document.createTextNode(String(child)));
  }
}

/**
 * Builds an HTML element. `attrs` keys: `class` (string or array), `onClick` and other `on*` listeners, `dataset`,
 * `style` (object, via CSSOM), `ref` (called with the element), `value`/`checked` (set as properties), anything
 * else as an attribute (`true` → empty attribute; `false`/`null`/`undefined` → omitted). Children may be nodes,
 * strings, numbers, arrays, or null/false (skipped).
 */
export function h(tag, attrs, ...children) {
  return build(document.createElement(tag), attrs, children);
}

/** Builds an SVG element; same rules as `h`. */
export function svg(tag, attrs, ...children) {
  return build(document.createElementNS(SVG_NS, tag), attrs, children);
}

/** Replaces all children of `element`. */
export function replaceChildren(element, ...children) {
  element.replaceChildren();
  append(element, children);
  return element;
}

// MARK: Page structure

/**
 * A page: the large title (and optional subtitle and trailing actions) followed by the content. The shell shows
 * the title in the compact header once the large title scrolls away.
 */
export function page({ title, subtitle, actions }, ...content) {
  return h('div', { class: 'page' },
    h('header', { class: 'page-header' },
      h('div', { class: 'page-heading' },
        h('h1', { class: 'large-title' }, title),
        subtitle ? h('p', { class: 'page-subtitle' }, subtitle) : null),
      actions ? h('div', { class: 'page-actions' }, actions) : null),
    content);
}

/** A titled group of content, like a section of an inset grouped list. */
export function section({ title, footer, actions }, ...content) {
  return h('section', { class: 'section' },
    title || actions
      ? h('div', { class: 'section-header' }, title ? h('h2', { class: 'section-title' }, title) : null, actions)
      : null,
    content,
    footer ? h('p', { class: 'section-footer' }, footer) : null);
}

/** A rounded card. */
export function card(attrs, ...children) {
  const { class: extra, ...rest } = attrs ?? {};
  return h('div', { class: ['card', extra], ...rest }, children);
}

/** A centred message for a page or section with nothing to show yet. `icon` is an SVG element. */
export function emptyState({ icon, title, message, action }) {
  return h('div', { class: 'empty-state' },
    icon ? h('div', { class: 'empty-state-icon', 'aria-hidden': 'true' }, icon) : null,
    h('p', { class: 'empty-state-title' }, title),
    message ? h('p', { class: 'empty-state-message' }, message) : null,
    action ? h('div', { class: 'empty-state-action' }, action) : null);
}

/** A button. `kind`: `primary`, `secondary` (default), `destructive` or `plain`. */
export function button(label, { kind = 'secondary', onClick, type = 'button', ...attrs } = {}) {
  return h('button', { type, class: ['button', `button-${kind}`], onClick, ...attrs }, label);
}

/** An indeterminate activity indicator. */
export function spinner(label = 'Loading') {
  return h('span', { class: 'spinner', role: 'progressbar', 'aria-label': label });
}

// MARK: Sheet

const openSheets = [];

function focusable(root) {
  return [...root.querySelectorAll(
    'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), ' +
    'textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
  )].filter((element) => element.getClientRects().length > 0);
}

let sheetCount = 0;

/**
 * Opens a modal sheet and returns `{ close, element, setError }`.
 *
 * `body` is a node (or array of nodes). Each action is `{ label, kind, onClick, disabled }`; `kind` is `primary`,
 * `destructive`, `cancel` or `secondary`. Clicking an action runs `onClick(sheet)`; while its promise is pending
 * the buttons are disabled. Afterwards the sheet closes, unless `onClick` returned `false` or threw — a thrown
 * error's message is shown inside the sheet. Esc, the close button and a click on the backdrop close it, focus
 * stays inside while it is open and returns to where it was afterwards. `onClose` runs once it has closed.
 */
export function sheet({ title, body, actions = [{ label: 'Done', kind: 'primary' }], onClose } = {}) {
  const id = `sheet-title-${++sheetCount}`;
  const returnFocus = document.activeElement;
  const error = h('p', { class: 'sheet-error', role: 'alert', hidden: true });
  let closed = false;
  let busy = false;

  const buttons = actions.map((action) => h('button', {
    type: 'button',
    class: ['button', `button-${action.kind === 'cancel' ? 'secondary' : action.kind ?? 'secondary'}`],
    disabled: action.disabled,
    onClick: () => run(action),
  }, action.label));

  const closeButton = h('button', { type: 'button', class: 'sheet-close', 'aria-label': 'Close', onClick: () => close() },
    svg('svg', { viewBox: '0 0 24 24', 'aria-hidden': 'true' },
      svg('path', { d: 'M7 7l10 10M17 7L7 17' })));

  const panel = h('div', { class: 'sheet', role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': id, tabindex: '-1' },
    h('header', { class: 'sheet-header' }, h('h2', { class: 'sheet-title', id }, title), closeButton),
    h('div', { class: 'sheet-body' }, body, error),
    buttons.length ? h('footer', { class: 'sheet-actions' }, buttons) : null);

  const backdrop = h('div', { class: 'sheet-backdrop' }, panel);
  backdrop.addEventListener('mousedown', (event) => {
    if (event.target === backdrop) backdrop.dataset.pressed = 'true';
  });
  backdrop.addEventListener('click', (event) => {
    // Only a press that started and ended on the backdrop closes, not a text selection dragged out of the sheet.
    if (event.target === backdrop && backdrop.dataset.pressed === 'true') close();
    delete backdrop.dataset.pressed;
  });
  backdrop.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.stopPropagation();
      close();
    } else if (event.key === 'Tab') {
      trap(event);
    }
  });

  function trap(event) {
    const items = focusable(panel);
    if (items.length === 0) {
      event.preventDefault();
      panel.focus();
      return;
    }
    const first = items[0];
    const last = items[items.length - 1];
    if (event.shiftKey && (document.activeElement === first || document.activeElement === panel)) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  async function run(action) {
    if (busy) return;
    error.hidden = true;
    if (!action.onClick) return close();
    busy = true;
    buttons.forEach((b) => { b.disabled = true; });
    try {
      const result = await action.onClick(handle);
      if (result !== false) close();
    } catch (failure) {
      setError(failure?.message ?? String(failure));
    } finally {
      busy = false;
      if (!closed) buttons.forEach((b, i) => { b.disabled = Boolean(actions[i].disabled); });
    }
  }

  function setError(message) {
    error.textContent = message ?? '';
    error.hidden = !message;
  }

  // Everything behind the sheet becomes inert: unreachable by Tab, clicks and assistive technology.
  const madeInert = [...document.body.children].filter((element) => !element.inert);
  madeInert.forEach((element) => { element.inert = true; });

  function close() {
    if (closed) return;
    closed = true;
    openSheets.splice(openSheets.indexOf(handle), 1);
    madeInert.forEach((element) => { element.inert = false; });
    backdrop.classList.add('closing');
    const remove = () => backdrop.remove();
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) remove();
    else {
      backdrop.addEventListener('animationend', remove, { once: true });
      setTimeout(remove, 400);
    }
    if (returnFocus instanceof HTMLElement && returnFocus.isConnected) returnFocus.focus();
    onClose?.();
  }

  const handle = { close, element: panel, setError };
  openSheets.push(handle);
  document.body.append(backdrop);
  (panel.querySelector('[autofocus]') ?? focusable(panel.querySelector('.sheet-body'))[0] ?? panel).focus();
  return handle;
}

/** Closes every open sheet (the router does this on navigation). */
export function closeAllSheets() {
  [...openSheets].reverse().forEach((s) => s.close());
}

/** Asks a yes/no question in a sheet. Resolves to true when confirmed. */
export function confirm({ title, message, confirmLabel = 'OK', destructive = false }) {
  return new Promise((resolve) => {
    let confirmed = false;
    sheet({
      title,
      body: message ? h('p', { class: 'sheet-message' }, message) : null,
      actions: [
        { label: 'Cancel', kind: 'cancel' },
        { label: confirmLabel, kind: destructive ? 'destructive' : 'primary', onClick: () => { confirmed = true; } },
      ],
      onClose: () => resolve(confirmed),
    });
  });
}

// MARK: Toast

let toastRegion;

/** Shows a short message at the edge of the screen. `kind`: `info` (default), `success` or `error`. */
export function toast(message, kind = 'info') {
  if (!toastRegion?.isConnected) {
    toastRegion = h('div', { class: 'toasts', role: 'status', 'aria-live': 'polite' });
    document.body.append(toastRegion);
  }
  const item = h('div', { class: ['toast', `toast-${kind}`] }, message);
  const dismiss = () => {
    if (!item.isConnected) return;
    item.classList.add('leaving');
    setTimeout(() => item.remove(), 250);
  };
  item.addEventListener('click', dismiss);
  toastRegion.append(item);
  setTimeout(dismiss, kind === 'error' ? 6000 : 4000);
  return dismiss;
}

// MARK: Ring

/**
 * A circular gauge for a fraction from 0 to 1 (null when unknown), with the percentage in the middle. `label`
 * names it for assistive technology, e.g. "CPU 42%". Colour: accent below 70 %, warning below 90 %, failure above.
 */
export function ring(fraction, label) {
  const known = typeof fraction === 'number' && Number.isFinite(fraction);
  const value = known ? Math.min(Math.max(fraction, 0), 1) : 0;
  const radius = 15.5;
  const circumference = 2 * Math.PI * radius;
  const level = !known ? 'unknown' : value >= 0.9 ? 'high' : value >= 0.7 ? 'medium' : 'low';
  return svg('svg', { class: ['ring', `ring-${level}`], viewBox: '0 0 40 40', role: 'img', 'aria-label': label },
    svg('circle', { class: 'ring-track', cx: 20, cy: 20, r: radius }),
    svg('circle', {
      class: 'ring-value', cx: 20, cy: 20, r: radius,
      'stroke-dasharray': `${(value * circumference).toFixed(2)} ${circumference.toFixed(2)}`,
      transform: 'rotate(-90 20 20)',
    }),
    svg('text', { class: 'ring-text', x: 20, y: 20, 'text-anchor': 'middle', 'dominant-baseline': 'central', 'aria-hidden': 'true' },
      known ? `${Math.round(value * 100)}%` : '–'));
}

// MARK: Formatting

const relativeFormat = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
const dateFormat = new Intl.DateTimeFormat('en', { month: 'short', day: 'numeric' });
const yearFormat = new Intl.DateTimeFormat('en', { year: 'numeric', month: 'short', day: 'numeric' });

function toDate(value) {
  if (value === null || value === undefined || value === '') return null;
  const date = value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

/** "just now", "5 minutes ago", "yesterday", then "Nov 4" (with the year when it is not this year). */
export function relativeTime(value, now = new Date()) {
  const date = toDate(value);
  if (!date) return '–';
  const seconds = Math.round((date - now) / 1000);
  const abs = Math.abs(seconds);
  if (abs < 45) return 'just now';
  if (abs < 3600) return relativeFormat.format(Math.round(seconds / 60), 'minute');
  if (abs < 86400) return relativeFormat.format(Math.round(seconds / 3600), 'hour');
  if (abs < 7 * 86400) return relativeFormat.format(Math.round(seconds / 86400), 'day');
  return (date.getFullYear() === now.getFullYear() ? dateFormat : yearFormat).format(date);
}

/** Elapsed time from `start` to `end` (or now): "8s", "3m 05s", "1h 02m". "–" without a start. */
export function duration(start, end) {
  const from = toDate(start);
  if (!from) return '–';
  const to = toDate(end) ?? new Date();
  const total = Math.max(0, Math.round((to - from) / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const pad = (n) => String(n).padStart(2, '0');
  if (hours > 0) return `${hours}h ${pad(minutes)}m`;
  if (minutes > 0) return `${minutes}m ${pad(seconds)}s`;
  return `${seconds}s`;
}

// MARK: Status

const STATUS_LABELS = {
  queued: 'Queued',
  assigned: 'Assigned',
  running: 'Running',
  succeeded: 'Succeeded',
  failed: 'Failed',
  cancelled: 'Cancelled',
  pending: 'Pending',
  skipped: 'Skipped',
};

/** A pill with a coloured dot for a build, job or step status. */
export function statusBadge(status) {
  const known = Object.hasOwn(STATUS_LABELS, status);
  return h('span', { class: ['badge', `badge-${known ? status : 'unknown'}`] },
    h('span', { class: 'badge-dot', 'aria-hidden': 'true' }),
    known ? STATUS_LABELS[status] : String(status ?? 'Unknown'));
}

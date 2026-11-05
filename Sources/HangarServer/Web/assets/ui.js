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
    } else if (key === 'style') {
      // CSSOM writes are allowed by the CSP; a style="" attribute would not be.
      if (typeof value !== 'object') {
        console.warn('h(): style must be an object of properties; the CSP blocks a style string', value);
        continue;
      }
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
 * A page: the large title (and optional subtitle and trailing actions) followed by the content. `leading` (a
 * node, e.g. an app icon) sits before the title. The shell shows the title in the compact header once the large
 * title scrolls away.
 */
export function page({ title, subtitle, actions, leading }, ...content) {
  // The actions share the title's row, so they centre on its first line on every page, with or without a
  // subtitle or a leading icon.
  return h('div', { class: 'page' },
    h('header', { class: 'page-header' },
      leading ? h('div', { class: 'page-leading' }, leading) : null,
      h('div', { class: 'page-heading' },
        h('div', { class: 'page-title-row' },
          h('h1', { class: 'large-title' }, title),
          actions ? h('div', { class: 'page-actions' }, actions) : null),
        subtitle ? h('p', { class: 'page-subtitle' }, subtitle) : null)),
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

/** A check mark in a filled circle, as on finished steps. */
export function checkBadge(className = 'check-badge') {
  return h('span', { class: className, 'aria-hidden': 'true' },
    svg('svg', { viewBox: '0 0 20 20', focusable: 'false' }, svg('path', { d: 'M5.5 10.5l3 3 6-7' })));
}

/** A button. `kind`: `primary`, `secondary` (default), `destructive` or `plain`. */
export function button(label, { kind = 'secondary', onClick, type = 'button', ...attrs } = {}) {
  return h('button', { type, class: ['button', `button-${kind}`], onClick, ...attrs }, label);
}

/** An indeterminate activity indicator. */
export function spinner(label = 'Loading') {
  return h('span', { class: 'spinner', role: 'progressbar', 'aria-label': label });
}

// MARK: Forms

let fieldCount = 0;

/**
 * A labelled form field. `control` is an input, textarea or select (it gets an id when it has none); the label is
 * tied to it and `hint` (text or node) becomes its description. Returns the field element.
 */
export function field({ label, hint, control, trailing }) {
  const id = control.id || `field-${++fieldCount}`;
  control.id = id;
  const hintNode = hint ? h('p', { class: 'field-hint', id: `${id}-hint` }, hint) : null;
  if (hintNode) control.setAttribute('aria-describedby', hintNode.id);
  return h('div', { class: 'field' },
    h('div', { class: 'field-label-row' }, h('label', { class: 'field-label', for: id }, label), trailing),
    control,
    hintNode);
}

/**
 * An on/off switch with a label and optional hint, built on a checkbox with `role="switch"`. `onChange(checked)`
 * runs on every change. Returns `{ element, input }`.
 */
export function switchField({ label, hint, checked = false, disabled = false, onChange }) {
  const id = `switch-${++fieldCount}`;
  const input = h('input', {
    type: 'checkbox', role: 'switch', class: 'switch', id, checked, disabled,
    'aria-describedby': hint ? `${id}-hint` : null,
    onChange: () => onChange?.(input.checked),
  });
  const element = h('div', { class: 'switch-field' },
    h('div', { class: 'switch-text' },
      h('label', { class: 'field-label', for: id }, label),
      hint ? h('p', { class: 'field-hint', id: `${id}-hint` }, hint) : null),
    input);
  return { element, input };
}

// MARK: Sheet

const openSheets = []; // { handle, backdrop }, topmost last
const inertBySheets = new Set();

/**
 * Makes everything in <body> but the topmost sheet inert, so it cannot be reached by Tab, pointer or assistive
 * technology. Toasts stay live. Elements made inert here are released once no sheet needs them inert any more;
 * elements that were already inert are left alone.
 */
function syncInert() {
  const top = openSheets.at(-1)?.backdrop;
  for (const element of [...inertBySheets]) {
    if (!top || element === top || !element.isConnected) {
      element.inert = false;
      inertBySheets.delete(element);
    }
  }
  if (!top) return;
  for (const element of document.body.children) {
    if (element === top || element.classList.contains('toasts') || element.inert) continue;
    element.inert = true;
    inertBySheets.add(element);
  }
}

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
 * stays inside while it is open and returns to where it was afterwards. `onClose` runs once it has closed. With
 * `submitOnEnter`, Return in a single-line input runs the first primary action, as in a form. `beforeDismiss`
 * (async, resolving to a boolean) is asked before Esc, the close button or the backdrop closes the sheet; false
 * keeps it open. Actions and `close()` are not asked. `setActions(actions)` on the returned handle replaces the
 * footer's buttons. `anchor: 'top'` pins the sheet's top edge, so a sheet that changes height grows downwards.
 */
export function sheet({
  title, body, actions = [{ label: 'Done', kind: 'primary' }], onClose, submitOnEnter = false, beforeDismiss,
  anchor = 'center',
} = {}) {
  const id = `sheet-title-${++sheetCount}`;
  const returnFocus = document.activeElement;
  const error = h('p', { class: 'sheet-error', role: 'alert', hidden: true });
  let closed = false;
  let busy = false;
  let asking = false;

  let buttons = [];
  const footer = h('footer', { class: 'sheet-actions' });

  /** Replaces the footer's buttons (a stepped sheet's Back and Next, say). */
  function setActions(list) {
    actions = list ?? [];
    buttons = actions.map((action) => h('button', {
      type: 'button',
      class: ['button', `button-${action.kind === 'cancel' ? 'secondary' : action.kind ?? 'secondary'}`],
      disabled: action.disabled || busy,
      onClick: () => run(action),
    }, action.label));
    replaceChildren(footer, buttons);
    footer.hidden = buttons.length === 0;
  }

  const closeButton = h('button', { type: 'button', class: 'sheet-close', 'aria-label': 'Close', onClick: () => dismiss() },
    svg('svg', { viewBox: '0 0 24 24', 'aria-hidden': 'true' },
      svg('path', { d: 'M7 7l10 10M17 7L7 17' })));

  const panel = h('div', { class: 'sheet', role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': id, tabindex: '-1' },
    h('header', { class: 'sheet-header' }, h('h2', { class: 'sheet-title', id }, title), closeButton),
    h('div', { class: 'sheet-body' }, body, error),
    footer);
  setActions(actions);

  // `anchor: 'top'` keeps the top edge fixed for a sheet whose height changes (a stepped flow).
  const backdrop = h('div', { class: ['sheet-backdrop', anchor === 'top' && 'sheet-backdrop-top'] }, panel);
  backdrop.addEventListener('mousedown', (event) => {
    if (event.target === backdrop) backdrop.dataset.pressed = 'true';
  });
  backdrop.addEventListener('click', (event) => {
    // Only a press that started and ended on the backdrop closes, not a text selection dragged out of the sheet.
    if (event.target === backdrop && backdrop.dataset.pressed === 'true') dismiss();
    delete backdrop.dataset.pressed;
  });
  backdrop.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.stopPropagation();
      dismiss();
    } else if (event.key === 'Tab') {
      trap(event);
    } else if (event.key === 'Enter' && submitOnEnter && !event.isComposing && event.target instanceof HTMLInputElement
      && !['checkbox', 'radio', 'button', 'submit'].includes(event.target.type)) {
      const index = actions.findIndex((action) => action.kind === 'primary');
      if (index < 0 || buttons[index].disabled) return;
      event.preventDefault();
      run(actions[index]);
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

  async function dismiss() {
    if (closed || asking) return;
    if (beforeDismiss) {
      asking = true;
      try {
        if (!(await beforeDismiss())) return;
      } finally {
        asking = false;
      }
    }
    close();
  }

  function close() {
    if (closed) return;
    closed = true;
    openSheets.splice(openSheets.findIndex((entry) => entry.handle === handle), 1);
    syncInert();
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

  const handle = { close, element: panel, setError, setActions };
  openSheets.push({ handle, backdrop });
  document.body.append(backdrop);
  syncInert();
  (panel.querySelector('[autofocus]') ?? focusable(panel.querySelector('.sheet-body'))[0] ?? panel).focus();
  return handle;
}

/** Closes every open sheet (the router does this on navigation). */
export function closeAllSheets() {
  [...openSheets].reverse().forEach((entry) => entry.handle.close());
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

// MARK: Clipboard

/**
 * Copies `text` to the clipboard. Resolves to true when it was copied. The Clipboard API needs a secure context,
 * which Hangar over plain HTTP on the tailnet is not, so it falls back to selecting a hidden textarea and
 * `execCommand('copy')`. Focus returns to where it was. Callers show their own fallback (e.g. select the text)
 * when this resolves to false.
 */
export async function copyText(text) {
  if (window.isSecureContext && navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      // Denied permission, say: try the selection route below.
    }
  }
  const previous = document.activeElement;
  // Not readonly: iOS does not select text in a readonly field. Fixed at the top left so focusing it never scrolls.
  const area = h('textarea', { class: 'clipboard-proxy', 'aria-hidden': 'true', tabindex: '-1' });
  area.value = text;
  document.body.append(area);
  let copied = false;
  try {
    area.focus({ preventScroll: true });
    area.select();
    area.setSelectionRange(0, text.length);
    copied = document.execCommand('copy');
  } catch {
    copied = false;
  } finally {
    area.remove();
    if (previous instanceof HTMLElement && previous.isConnected) previous.focus({ preventScroll: true });
  }
  return copied;
}

/** Selects the text inside `element`, so the user can copy it by hand. */
export function selectContents(element) {
  const selection = window.getSelection();
  if (!selection) return;
  const range = document.createRange();
  range.selectNodeContents(element);
  selection.removeAllRanges();
  selection.addRange(range);
}

// MARK: Ring

/**
 * A circular gauge for a fraction from 0 to 1 (null when unknown), with the percentage in the middle. `label`
 * names it for assistive technology, e.g. "1 of 1 job running". Always the accent colour: a full machine is busy,
 * not in trouble, so red stays for offline and failures.
 */
export function ring(fraction, label) {
  const known = typeof fraction === 'number' && Number.isFinite(fraction);
  const value = known ? Math.min(Math.max(fraction, 0), 1) : 0;
  const radius = 15.5;
  const circumference = 2 * Math.PI * radius;
  const level = known ? 'known' : 'unknown';
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

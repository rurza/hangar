// Pieces the workflow editor and the new-workflow wizard share: glyphs, plain-language sentences, choice controls
// and the TestFlight group picker with its "+ New Group".

import { api, ApiError } from '../api.js';
import { h, plusIcon, replaceChildren, spinner, svg } from '../ui.js';

// MARK: Glyphs

// 24 × 24 outline glyphs, drawn so their visual centre is the box's centre.
const GLYPHS = {
  general: [['path', { d: 'M4 7h9M17 7h3M4 17h3M11 17h9' }], ['circle', { cx: 15, cy: 7, r: 2 }], ['circle', { cx: 9, cy: 17, r: 2 }]],
  environment: [['path', { d: 'M12 3.5l7.5 4.25v8.5L12 20.5l-7.5-4.25v-8.5z' }], ['path', { d: 'M4.5 7.75L12 12l7.5-4.25M12 12v8.5' }]],
  // A triangle's visual centre sits left of its box's centre, so the box is nudged right.
  start: [['path', { d: 'M8.5 5.5v13l10-6.5z' }]],
  archive: [['rect', { x: 3.5, y: 4.5, width: 17, height: 4.5, rx: 1 }], ['path', { d: 'M5 9v9.5a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9M10 13h4' }]],
  test: [['path', { d: 'M12 3l9 9-9 9-9-9z' }], ['path', { d: 'M8.75 12.25l2.25 2.25 4.25-4.5' }]],
  testflight: [['path', { d: 'M20.5 3.5L3.5 10.5l7 3 3 7z' }], ['path', { d: 'M10.5 13.5l10-10' }]],
  ios: [['rect', { x: 7, y: 3, width: 10, height: 18, rx: 2.5 }], ['path', { d: 'M11 17.5h2' }]],
  macos: [['rect', { x: 3.5, y: 4.5, width: 17, height: 11, rx: 1.5 }], ['path', { d: 'M2 19.5h20' }]],
  visionos: [['path', { d: 'M3 10.5c0-2.5 2-4 9-4s9 1.5 9 4v1c0 3-1.5 5-4 5-2 0-3-2-5-2s-3 2-5 2c-2.5 0-4-2-4-5z' }]],
  tvos: [['rect', { x: 3, y: 4.5, width: 18, height: 12, rx: 1.5 }], ['path', { d: 'M8 20h8' }]],
  watchos: [['rect', { x: 6.5, y: 6, width: 11, height: 12, rx: 3 }], ['path', { d: 'M9 6l.5-3h5l.5 3M9 18l.5 3h5l.5-3' }]],
};

/** An outline glyph by name (`general`, `archive`, `ios`...). */
export function glyph(name, className = 'wf-glyph') {
  return svg('svg', { class: className, viewBox: '0 0 24 24', 'aria-hidden': 'true', focusable: 'false' },
    (GLYPHS[name] ?? GLYPHS.general).map(([tag, attrs]) => svg(tag, attrs)));
}

/** A colour tile with a white glyph; `tone` picks the colour (`archive`, `test`, `platform`...). */
export function tile(name, tone = name) {
  return h('span', { class: ['wf-tile', `wf-tone-${tone}`], 'aria-hidden': 'true' }, glyph(name));
}

/** The plus of an add row: ui.js's shared plus icon in a filled accent circle (22 px, the checkboxes' column). */
export function plusGlyph() {
  return h('span', { class: 'wf-plus-circle', 'aria-hidden': 'true' }, plusIcon());
}

export function chevron(direction = 'right') {
  return direction === 'left'
    ? svg('svg', { viewBox: '0 0 12 20', 'aria-hidden': 'true' }, svg('path', { d: 'M10 2L2 10l8 8' }))
    : svg('svg', { class: 'wf-row-chevron', viewBox: '0 0 8 14', 'aria-hidden': 'true' }, svg('path', { d: 'M1.5 1.5L6.5 7l-5 5.5' }));
}

// MARK: Words

/** A sentence from workflow-model.js (strings and `{strong}` pieces) as nodes. */
export function sentence(pieces) {
  return pieces.map((piece) => (typeof piece === 'string' ? piece : h('strong', null, piece.strong)));
}

/** The "what this does" box. */
export function explain(pieces) {
  return h('p', { class: 'wf-explain' }, sentence(pieces));
}

/** What detection guessed about a field (workflow-model.js's `detectionNotes`), in small secondary text under it;
 * null without notes. */
export function guessNotes(list) {
  return list?.length ? h('div', { class: 'wf-guesses' }, list.map((text) => h('p', { class: 'wf-guess' }, text))) : null;
}

// MARK: Controls

let controlCount = 0;

/**
 * Radio cards: `options` are `{ value, title, detail, disabled, extra }`; `extra` (a node) shows under the checked
 * one. `onChange(value)` runs on a pick. Returns the fieldset.
 */
export function choiceCards({ name, legend, value, options, onChange }) {
  const group = `wf-choice-${++controlCount}`;
  return h('fieldset', { class: 'wf-choices' },
    legend ? h('legend', { class: 'visually-hidden' }, legend) : null,
    options.map((option) => {
      const id = `${group}-${option.value}`;
      const input = h('input', {
        type: 'radio', class: 'wf-radio', name: name ?? group, id, value: option.value, checked: option.value === value,
        disabled: option.disabled, 'aria-describedby': option.detail ? `${id}-detail` : null,
        onChange: () => { if (input.checked) onChange?.(option.value); },
      });
      // The extra controls sit beside the label, not in it, so they keep their own names and clicks.
      return h('div', { class: 'wf-choice' },
        h('label', { class: 'wf-choice-main', for: id },
          input,
          h('span', { class: 'wf-choice-text' },
            h('span', { class: 'wf-choice-title' }, option.title),
            option.detail ? h('span', { class: 'wf-choice-detail', id: `${id}-detail` }, option.detail) : null)),
        option.value === value && option.extra ? h('div', { class: 'wf-choice-extra' }, option.extra) : null);
    }));
}

/** A checklist row: a checkbox, its title and detail, and a trailing tag. */
export function checkRow({ title, detail, tag, tagWarning, checked, disabled, onChange }) {
  const id = `wf-check-${++controlCount}`;
  const input = h('input', {
    type: 'checkbox', class: 'wf-checkbox', id, checked, disabled,
    onChange: () => onChange?.(input.checked),
  });
  return h('li', null,
    h('label', { class: 'wf-check', for: id },
      input,
      h('span', { class: 'wf-check-text' },
        h('span', { class: 'wf-check-title' }, title),
        detail ? h('span', { class: 'wf-check-detail' }, detail) : null),
      tag ? h('span', { class: ['wf-check-tag', tagWarning && 'wf-check-tag-warning'] }, tag) : null));
}

/** A segmented control of `options` (`[value, label]`) as radios; arrow keys move the choice. `onChange(value)`. */
export function segmented({ label, value, options, onChange }) {
  const buttons = options.map(([optionValue, text]) => h('button', {
    type: 'button', class: 'segment', role: 'radio', 'aria-checked': String(optionValue === value),
    tabindex: optionValue === value ? '0' : '-1', dataset: { value: optionValue },
    onClick: () => { if (optionValue !== value) onChange(optionValue); },
  }, text));
  const control = h('div', { class: 'segmented wf-segmented', role: 'radiogroup', 'aria-label': label }, buttons);
  control.addEventListener('keydown', (event) => {
    if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
    const index = buttons.indexOf(document.activeElement);
    if (index < 0) return;
    event.preventDefault();
    onChange(buttons[(index + (event.key === 'ArrowRight' ? 1 : buttons.length - 1)) % buttons.length].dataset.value);
  });
  return control;
}

/** The repository's branches (`GET /apps/{id}/branches`), loaded once: `{ defaultBranch, branches }`, or null. */
export function branchesStore(base) {
  let pending = null;
  return {
    state: undefined,
    load() {
      if (this.state !== undefined) return Promise.resolve(this.state);
      pending ??= api.get(`${base}/branches`).then(
        (result) => { this.state = result ?? null; return this.state; },
        () => { this.state = null; return null; },
      );
      return pending;
    },
  };
}

// MARK: TestFlight groups

/**
 * The app's TestFlight groups, loaded once and shared by whoever asks: `load()` resolves to
 * `{ groups: [{id, name, isInternal}] }`, `{ notConfigured: true }` or `{ error }`; `create(name, { internal })`
 * makes a group (internal unless `internal` is false) and adds it to the list.
 */
export function betaGroupsStore(base) {
  let pending = null;
  let state = null;
  return {
    get state() { return state; },
    load({ refresh = false } = {}) {
      if (state && !refresh) return Promise.resolve(state);
      if (pending && !refresh) return pending;
      pending = api.get(`${base}/beta-groups`).then(
        (groups) => { state = { groups: groups ?? [] }; return state; },
        (error) => {
          state = error instanceof ApiError && error.code === 'asc_not_configured' ? { notConfigured: true } : { error };
          return state;
        },
      ).finally(() => { pending = null; });
      return pending;
    },
    async create(name, { internal: isInternal = true } = {}) {
      const group = await api.post(`${base}/beta-groups`, { name, isInternal });
      if (state?.groups) state = { groups: [...state.groups.filter((g) => g.id !== group.id), group] };
      return group;
    },
  };
}

/**
 * The groups checklist with "+ New Group". `selected` (an array of names) is edited in place; `onChange()` runs
 * after each change. `internalOnly` lists internal groups only. `disabled` greys the list (no processing wait).
 */
export function groupPicker({ store, selected, onChange, internalOnly = false, disabled = false }) {
  const element = h('div', { class: 'wf-field' });
  let adding = false;
  let addError = null;
  let draft = '';
  let external = false;

  function draw() {
    const state = store.state;
    if (!state) {
      replaceChildren(element, h('p', { class: 'wf-status-line' }, spinner('Loading groups'), 'Loading groups from App Store Connect…'));
      store.load().then(() => draw());
      return;
    }
    if (state.notConfigured) {
      replaceChildren(element,
        h('p', { class: 'wf-note wf-note-warning' }, 'Add the App Store Connect key in ',
          h('a', { href: '/settings', 'data-link': true }, 'Settings'), ' to pick groups.'),
        selected.length ? h('p', { class: 'wf-note' }, `Groups: ${selected.join(', ')}`) : null);
      return;
    }
    if (state.error) {
      replaceChildren(element,
        h('p', { class: 'wf-note wf-note-warning' }, `The groups could not be loaded. ${state.error.message}`),
        h('button', { type: 'button', class: 'wf-more', onClick: () => store.load({ refresh: true }).then(draw) }, 'Try Again'));
      return;
    }
    const known = state.groups.filter((group) => !internalOnly || group.isInternal);
    const names = new Set(state.groups.map((group) => group.name));
    const missing = selected.filter((name) => !names.has(name));
    const toggle = (name, on) => {
      const index = selected.indexOf(name);
      if (on && index < 0) selected.push(name);
      if (!on && index >= 0) selected.splice(index, 1);
      onChange?.();
    };
    const rows = [
      ...known.map((group) => checkRow({
        title: group.name, tag: internalOnly ? null : group.isInternal ? 'Internal' : 'External', checked: selected.includes(group.name), disabled,
        onChange: (on) => toggle(group.name, on),
      })),
      // A name in the workflow that App Store Connect does not have: shown, so it can be unticked.
      ...missing.map((name) => checkRow({
        title: name, tag: 'Not in App Store Connect', tagWarning: true, checked: true, disabled,
        onChange: (on) => { toggle(name, on); draw(); },
      })),
    ];
    const list = h('ul', { class: 'wf-checklist', 'aria-label': 'TestFlight groups' }, rows, addRow());
    const selectedExternal = known.filter((group) => !group.isInternal && selected.includes(group.name));
    let hint;
    if (!(known.length || missing.length)) {
      hint = 'This app has no groups yet. Create one, or pick none: App Store Connect users with access still see each build.';
    } else if (selectedExternal.length) {
      const names = selectedExternal.map((group) => group.name);
      hint = `${names.length === 1 ? `${names[0]} is an external group` : `${names.join(', ')} are external groups`}. The build goes to Apple’s beta review before those testers get it.`;
    } else if (internalOnly || known.every((group) => group.isInternal)) {
      hint = 'Internal groups contain people on your App Store Connect team.';
    } else {
      hint = 'Internal groups are people on your App Store Connect team. External groups get the build after Apple’s beta review.';
    }
    replaceChildren(element, list, h('p', { class: 'wf-field-hint' }, hint));
  }

  function addRow() {
    if (disabled) return null;
    if (!adding) {
      return h('li', null, h('button', {
        type: 'button', class: 'wf-add-row',
        onClick: () => {
          adding = true;
          addError = null;
          draw();
          element.querySelector('.wf-new-group input')?.focus();
        },
      }, plusGlyph(), 'New Group'));
    }
    const input = h('input', {
      class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', placeholder: 'Group name',
      'aria-label': 'New group name', value: draft, 'aria-invalid': addError ? 'true' : null,
      onInput: (event) => { draft = event.target.value; },
      onKeydown: (event) => {
        if (event.key === 'Enter' && !event.isComposing) {
          event.preventDefault();
          event.stopPropagation();
          create();
        } else if (event.key === 'Escape') {
          event.stopPropagation();
          cancel();
        }
      },
    });
    const createButton = h('button', { type: 'button', class: 'button button-primary button-small', onClick: create }, 'Create Group');
    async function create() {
      const name = draft.trim();
      if (!name) {
        addError = 'Name the group.';
        draw();
        element.querySelector('.wf-new-group input')?.focus();
        return;
      }
      createButton.disabled = true;
      input.disabled = true;
      replaceChildren(createButton, 'Creating…');
      try {
        const group = await store.create(name, { internal: internalOnly || !external });
        if (!selected.includes(group.name)) selected.push(group.name);
        adding = false;
        draft = '';
        external = false;
        addError = null;
        onChange?.();
      } catch (error) {
        addError = error.message;
      }
      draw();
      if (adding) element.querySelector('.wf-new-group input')?.focus();
    }
    function cancel() {
      adding = false;
      draft = '';
      external = false;
      addError = null;
      draw();
      element.querySelector('.wf-add-row')?.focus();
    }
    const kind = (value, label) => {
      const inputKind = h('input', {
        type: 'radio', name: 'new-group-kind', value, checked: external === (value === 'external'),
        onChange: () => { external = value === 'external'; draw(); element.querySelector('.wf-new-group input.input')?.focus(); },
      });
      return h('label', { class: 'wf-pill' }, inputKind, label);
    };
    return h('li', { class: 'wf-new-group' },
      input,
      internalOnly ? null : h('div', { class: 'wf-new-group-kind', role: 'radiogroup', 'aria-label': 'Who the group is for' },
        kind('internal', 'Internal'), kind('external', 'External')),
      addError ? h('p', { class: 'wf-field-error', role: 'alert' }, addError) : null,
      h('p', { class: 'wf-field-hint' }, external && !internalOnly
        ? 'An external group. Testers get the build after Apple’s beta review.'
        : 'An internal group. Add testers to it in App Store Connect.'),
      h('div', { class: 'wf-new-group-actions' },
        h('button', { type: 'button', class: 'button button-plain button-small', onClick: cancel }, 'Cancel'),
        createButton));
  }

  draw();
  return element;
}

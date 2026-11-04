// The environment-variables editor, for the global scope (Settings) and for one app. Values are write-only: the
// API returns names and flags only, and the editor never shows or pre-fills a value.

import { api, seg } from '../api.js';
import { button, confirm, field, h, relativeTime, replaceChildren, sheet, spinner, switchField, toast } from '../ui.js';

const NAME_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;

/** Global variables that Settings sets through its own cards; the global editor does not list them. */
export const RESERVED_GLOBAL_NAMES = ['HANGAR_ASC_KEY_ID', 'HANGAR_ASC_ISSUER_ID', 'HANGAR_ASC_KEY_PATH', 'HANGAR_GITHUB_TOKEN'];

/** Names only Settings may set: the App Store Connect key is always global. */
function settingsOnly(name, isGlobal) {
  if (/^HANGAR_ASC_/.test(name)) return true;
  return isGlobal && RESERVED_GLOBAL_NAMES.includes(name);
}

/**
 * The variables of `scope` (`"global"` or `{app: slug}`) as an inset list with Add, Replace and Delete. `signal`
 * (optional) cancels loading when the page is left.
 */
export function variablesEditor({ scope, signal }) {
  const isGlobal = scope === 'global';
  const base = isGlobal ? '/variables' : `/apps/${seg(scope.app)}/variables`;
  const element = h('div', { class: 'variables' });
  let variables = [];

  async function load() {
    replaceChildren(element, h('div', { class: 'list list-loading' }, spinner('Loading variables')));
    try {
      const all = await api.get(base, { signal });
      variables = all
        .filter((variable) => !(isGlobal && RESERVED_GLOBAL_NAMES.includes(variable.name)))
        .sort((a, b) => a.name.localeCompare(b.name));
      render();
    } catch (error) {
      if (error.code === 'aborted') return;
      replaceChildren(element,
        h('div', { class: 'list inline-error' },
          h('p', { class: 'inline-error-message' }, error.message),
          button('Try Again', { kind: 'plain', onClick: load })));
    }
  }

  function render() {
    const rows = variables.map((variable) => h('li', { class: 'row variable-row' },
      h('div', { class: 'row-main' },
        h('div', { class: 'variable-name mono' }, variable.name),
        h('div', { class: 'variable-meta' },
          h('span', { class: ['tag', variable.isSecret ? 'tag-secret' : null] }, variable.isSecret ? 'Secret' : 'Plain'),
          variable.asFile ? h('span', { class: 'tag' }, 'File') : null,
          h('span', { class: 'row-detail' }, `Updated ${relativeTime(variable.updatedAt)}`))),
      h('div', { class: 'row-actions' },
        button('Replace', {
          kind: 'plain',
          'aria-label': `Replace ${variable.name}`,
          onClick: () => openSheet(variable),
        }),
        button('Delete', {
          kind: 'plain-destructive',
          'aria-label': `Delete ${variable.name}`,
          onClick: () => remove(variable),
        }))));
    replaceChildren(element,
      h('ul', { class: 'list' },
        rows.length === 0
          ? h('li', { class: 'row' }, h('p', { class: 'row-detail' }, 'No variables yet.'))
          : rows,
        h('li', { class: 'row row-add' },
          h('button', { type: 'button', class: 'add-row-button', onClick: () => openSheet(null) },
            h('span', { class: 'add-row-plus', 'aria-hidden': 'true' }, '+'),
            'Add Variable'))));
  }

  async function remove(variable) {
    const confirmed = await confirm({
      title: `Delete ${variable.name}?`,
      message: isGlobal
        ? 'Jobs of every app stop getting this variable.'
        : 'Jobs of this app stop getting this variable. A global variable with the same name applies again.',
      confirmLabel: 'Delete',
      destructive: true,
    });
    if (!confirmed) return;
    try {
      await api.del(`${base}/${seg(variable.name)}`);
      toast(`Deleted ${variable.name}`, 'success');
    } catch (error) {
      toast(error.message, 'error');
    }
    load();
  }

  /** The Add sheet (`existing` null) or the Replace sheet for `existing`, which starts with an empty value. */
  function openSheet(existing) {
    let isSecret = existing ? existing.isSecret : false;
    let asFile = existing ? existing.asFile : false;
    let revealed = false;

    const nameInput = existing ? null : h('input', {
      class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
      autocorrect: 'off', placeholder: 'API_BASE_URL', autofocus: true,
      onInput: () => nameInput.removeAttribute('aria-invalid'),
    });

    // The value control is rebuilt when the toggles change; whatever was typed carries over.
    const valueSlot = h('div', { class: 'value-slot' });
    let valueControl = null;
    function buildValue() {
      const typed = valueControl?.value ?? '';
      const multiline = asFile;
      const attrs = {
        autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', autocorrect: 'off',
        'data-1p-ignore': true, 'data-lpignore': 'true',
        placeholder: existing ? 'New value' : null,
        onInput: () => valueControl.removeAttribute('aria-invalid'),
      };
      const masked = isSecret && !revealed;
      valueControl = multiline
        ? h('textarea', { class: ['textarea', masked ? 'textarea-masked' : null], rows: 6, ...attrs })
        : h('input', { class: 'input mono', type: masked ? 'password' : 'text', ...attrs });
      if (existing) valueControl.setAttribute('autofocus', '');
      valueControl.value = typed;
      const reveal = isSecret
        ? h('button', {
          type: 'button', class: 'field-toggle', 'aria-label': revealed ? 'Hide value' : 'Show value',
          onClick: () => {
            revealed = !revealed;
            buildValue();
            valueControl.focus();
          },
        }, revealed ? 'Hide' : 'Show')
        : null;
      const hint = asFile
        ? `Jobs get the path of a file that holds this text.${isSecret ? ' After saving it cannot be read back, only replaced.' : ''}`
        : isSecret ? 'Shown only while you type. After saving it cannot be read back, only replaced.' : null;
      replaceChildren(valueSlot, field({ label: 'Value', hint, control: valueControl, trailing: reveal }));
    }

    const secret = switchField({
      label: 'Secret',
      hint: 'Never shown again and masked in build logs.',
      checked: isSecret,
      onChange: (checked) => {
        isSecret = checked;
        revealed = false;
        buildValue();
      },
    });
    const file = switchField({
      label: 'As file',
      hint: 'For keys and certificates: the variable holds a file path instead of the text.',
      checked: asFile,
      onChange: (checked) => {
        asFile = checked;
        buildValue();
      },
    });
    buildValue();

    const body = h('div', { class: 'form' },
      existing
        ? h('p', { class: 'sheet-message' },
          'Type a new value for ', h('code', null, existing.name), '. The current value is not shown.')
        : field({
          label: 'Name',
          hint: 'Letters, digits and underscores; not starting with a digit.',
          control: nameInput,
        }),
      valueSlot,
      h('div', { class: 'switch-group' }, secret.element, file.element));

    sheet({
      title: existing ? `Replace ${existing.name}` : 'Add Variable',
      body,
      submitOnEnter: true,
      actions: [
        { label: 'Cancel', kind: 'cancel' },
        {
          label: existing ? 'Replace' : 'Add',
          kind: 'primary',
          onClick: async () => {
            const name = existing ? existing.name : nameInput.value.trim();
            if (!existing) {
              const problem = nameProblem(name);
              if (problem) {
                nameInput.setAttribute('aria-invalid', 'true');
                nameInput.focus();
                throw new Error(problem);
              }
            }
            const value = valueControl.value;
            if (isSecret && value === '') {
              valueControl.setAttribute('aria-invalid', 'true');
              valueControl.focus();
              throw new Error('Enter the secret’s value.');
            }
            await api.put(`${base}/${seg(name)}`, { value, isSecret, asFile });
            valueControl.value = '';
            toast(`Saved ${name}`, 'success');
            load();
          },
        },
      ],
    });
  }

  function nameProblem(name) {
    if (name === '') return 'Enter a name.';
    if (!NAME_PATTERN.test(name)) {
      return `“${name}” is not a valid name. Use letters, digits and underscores, and do not start with a digit.`;
    }
    if (settingsOnly(name, isGlobal)) return `${name} is set in Settings.`;
    if (variables.some((variable) => variable.name === name)) {
      return `${name} already exists. Use Replace to change its value.`;
    }
    return null;
  }

  load();
  return element;
}

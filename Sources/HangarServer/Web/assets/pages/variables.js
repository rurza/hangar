// The environment-variables editors: one scope's variables (Settings' global variables, a variable group's, or an
// app's, which can be limited to some of its workflows), and an app's linked variable groups. Values are write-only:
// the API returns names and flags only, and no editor ever shows or pre-fills a value.

import { api, seg } from '../api.js';
import { navigate } from '../router.js';
import {
  button, confirm, field, h, plusIcon, relativeTime, replaceChildren, sheet, spinner, switchField, toast,
} from '../ui.js';
import { checkRow, choiceCards } from './workflow-parts.js';
import {
  listText, looksSecret, normalizedWorkflows, overlapping, unknownWorkflowsText, workflowsText,
} from '../variable-model.js';

const NAME_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;

/** Global variables that Settings sets through its own cards; the global editor does not list them. */
export const RESERVED_GLOBAL_NAMES = ['HANGAR_ASC_KEY_ID', 'HANGAR_ASC_ISSUER_ID', 'HANGAR_ASC_KEY_PATH', 'HANGAR_GITHUB_TOKEN'];

/** Names Hangar sets for every job; the worker ignores variables with them (CIEnvironment.reservedNames). */
const JOB_RESERVED_NAMES = ['PATH', 'HOME', 'DEVELOPER_DIR', 'USER', 'LOGNAME', 'TMPDIR', 'SHELL'];

/** Names only Settings may set: the App Store Connect key is always global. */
function settingsOnly(name, isGlobal) {
  if (/^HANGAR_ASC_/.test(name)) return true;
  return isGlobal && RESERVED_GLOBAL_NAMES.includes(name);
}

/** "for all workflows", "for “Beta”", "for “Beta” and “Release”": the server's wording in its errors. */
function coverage(workflows) {
  return workflows.length === 0 ? 'for all workflows' : `for ${listText(workflows.map((name) => `“${name}”`))}`;
}

/** The query that names one app variable by its workflows (none: the one for all workflows). */
function workflowQuery(workflows) {
  const query = new URLSearchParams();
  for (const name of workflows) query.append('workflow', name);
  const text = query.toString();
  return text === '' ? '' : `?${text}`;
}

/**
 * The variables of `scope` as an inset list with Add, Replace (Edit for an app) and Delete. `scope` is `"global"`,
 * `{app: slug}` or `{group: id}`. For an app, `workflows` is a promise of its workflow names (null when they cannot be
 * read): a variable can then be limited to some, and a name that is not among them is flagged. `signal` (optional)
 * cancels loading when the page is left.
 */
export function variablesEditor({ scope, signal, workflows = Promise.resolve(null), onChange }) {
  const isGlobal = scope === 'global';
  const isApp = !isGlobal && scope.app !== undefined;
  const isGroup = !isGlobal && scope.group !== undefined;
  const base = isGlobal ? '/variables' : isApp ? `/apps/${seg(scope.app)}/variables` : `/variable-groups/${seg(scope.group)}/variables`;
  const element = h('div', { class: 'variables' });
  let variables = [];
  let known = null;

  async function load() {
    replaceChildren(element, h('div', { class: 'list list-loading' }, spinner('Loading variables')));
    try {
      const [all, names] = await Promise.all([
        api.get(base, { signal }),
        isApp ? workflows.catch(() => null) : null,
      ]);
      known = names;
      variables = all
        .filter((variable) => !(isGlobal && RESERVED_GLOBAL_NAMES.includes(variable.name)))
        .sort((a, b) => a.name.localeCompare(b.name) || (a.workflows ?? []).join().localeCompare((b.workflows ?? []).join()));
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
    const rows = variables.map((variable) => {
      const limited = variable.workflows ?? [];
      const warning = isApp ? unknownWorkflowsText(limited, known) : null;
      const label = isApp && limited.length ? `${variable.name} for ${listText(limited)}` : variable.name;
      return h('li', { class: 'row variable-row' },
        h('div', { class: 'row-main' },
          h('div', { class: 'variable-name mono' }, variable.name),
          h('div', { class: 'variable-meta' },
            isApp ? h('span', { class: ['tag', limited.length ? 'tag-workflows' : null] }, workflowsText(limited)) : null,
            h('span', { class: ['tag', variable.isSecret ? 'tag-secret' : null] }, variable.isSecret ? 'Secret' : 'Plain'),
            variable.asFile ? h('span', { class: 'tag' }, 'File') : null,
            h('span', { class: 'row-detail' }, `Updated ${relativeTime(variable.updatedAt)}`)),
          warning ? h('p', { class: 'variable-warning' }, warning) : null,
          !variable.isSecret && looksSecret(variable.name)
            ? h('p', { class: 'variable-hint' }, `Looks like a secret but is stored as plain text. ${isApp ? 'Edit' : 'Replace'} it to make it secret.`)
            : null),
        h('div', { class: 'row-actions' },
          button(isApp ? 'Edit' : 'Replace', {
            kind: 'plain',
            'aria-label': `${isApp ? 'Edit' : 'Replace'} ${label}`,
            onClick: () => openSheet(variable),
          }),
          button('Delete', {
            kind: 'plain-destructive',
            'aria-label': `Delete ${label}`,
            onClick: () => remove(variable),
          })));
    });
    replaceChildren(element,
      h('ul', { class: 'list' },
        rows.length === 0
          ? h('li', { class: 'row' }, h('p', { class: 'row-detail' }, 'No variables yet.'))
          : rows,
        h('li', { class: 'row row-add' },
          h('button', { type: 'button', class: 'add-row-button', onClick: () => openSheet(null) },
            h('span', { class: 'add-row-plus', 'aria-hidden': 'true' }, plusIcon()),
            'Add Variable'))));
  }

  function deleteMessage(variable) {
    if (isGlobal) return 'Jobs of every app stop getting this variable.';
    if (isGroup) return 'Jobs of the apps that link this group stop getting this variable.';
    const limited = variable.workflows ?? [];
    const others = variables.filter((other) => other !== variable && other.name === variable.name);
    if (limited.length && others.some((other) => (other.workflows ?? []).length === 0)) {
      return `Jobs of ${listText(limited)} get the value for all workflows instead.`;
    }
    return limited.length
      ? `Jobs of ${listText(limited)} stop getting this value. A linked group’s or a global variable with the same name applies again.`
      : 'Jobs of this app stop getting this variable. A linked group’s or a global variable with the same name applies again.';
  }

  async function remove(variable) {
    const limited = variable.workflows ?? [];
    const confirmed = await confirm({
      title: isApp && limited.length ? `Delete ${variable.name} for ${listText(limited)}?` : `Delete ${variable.name}?`,
      message: deleteMessage(variable),
      confirmLabel: 'Delete',
      destructive: true,
    });
    if (!confirmed) return;
    try {
      await api.del(`${base}/${seg(variable.name)}${isApp ? workflowQuery(limited) : ''}`);
      toast(`Deleted ${variable.name}`, 'success');
    } catch (error) {
      toast(error.message, 'error');
    }
    load();
    onChange?.();
  }

  /**
   * The Add sheet (`existing` null) or the Replace/Edit sheet for `existing`, which starts with an empty value. For an
   * app the sheet also picks the workflows, and Edit keeps the value when it is left empty.
   */
  function openSheet(existing) {
    let isSecret = existing ? existing.isSecret : false;
    let asFile = existing ? existing.asFile : false;
    let revealed = false;
    // The Add sheet makes a name that looks like a secret secret, until the person flips the switch themselves.
    let secretTouched = Boolean(existing);
    const editing = Boolean(existing) && isApp;

    const nameInput = existing ? null : h('input', {
      class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
      autocorrect: 'off', placeholder: 'API_BASE_URL', autofocus: true,
      onInput: () => {
        nameInput.removeAttribute('aria-invalid');
        if (secretTouched) return;
        const guess = looksSecret(nameInput.value.trim());
        if (guess === isSecret) return;
        isSecret = guess;
        secret.input.checked = guess;
        revealed = false;
        buildValue();
      },
    });

    // The value control is rebuilt when the toggles change; whatever was typed carries over.
    const valueSlot = h('div', { class: 'value-slot' });
    let valueControl = null;
    function buildValue() {
      const typed = valueControl?.value ?? '';
      const hadFocus = valueControl && document.activeElement === valueControl;
      const multiline = asFile;
      const attrs = {
        autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', autocorrect: 'off',
        'data-1p-ignore': true, 'data-lpignore': 'true',
        placeholder: editing ? 'Leave empty to keep the current value' : existing ? 'New value' : null,
        onInput: () => valueControl.removeAttribute('aria-invalid'),
      };
      const masked = isSecret && !revealed;
      valueControl = multiline
        ? h('textarea', { class: ['textarea', masked ? 'textarea-masked' : null], rows: 6, ...attrs })
        : h('input', { class: 'input mono', type: masked ? 'password' : 'text', ...attrs });
      if (existing && !editing) valueControl.setAttribute('autofocus', '');
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
      replaceChildren(valueSlot, field({ label: editing ? 'New Value' : 'Value', hint, control: valueControl, trailing: reveal }));
      if (hadFocus) valueControl.focus();
    }

    const secret = switchField({
      label: 'Secret',
      hint: 'Never shown again and masked in build logs.',
      checked: isSecret,
      onChange: (checked) => {
        secretTouched = true;
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

    const chooser = isApp ? workflowChooser({ selected: existing?.workflows ?? [], known, subject: 'variable' }) : null;

    const body = h('div', { class: 'form' },
      existing
        ? h('p', { class: 'sheet-message' },
          editing
            ? ['Change which workflows get ', h('code', null, existing.name), ' or type a new value. The current value is not shown.']
            : ['Type a new value for ', h('code', null, existing.name), '. The current value is not shown.'])
        : field({
          label: 'Name',
          hint: 'Letters, digits and underscores; not starting with a digit.',
          control: nameInput,
        }),
      chooser?.element,
      valueSlot,
      h('div', { class: 'switch-group' }, secret.element, file.element));

    sheet({
      title: existing ? `${editing ? 'Edit' : 'Replace'} ${existing.name}` : 'Add Variable',
      body,
      submitOnEnter: true,
      actions: [
        { label: 'Cancel', kind: 'cancel' },
        {
          label: existing ? (editing ? 'Save' : 'Replace') : 'Add',
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
            const chosen = chooser ? chooser.value() : [];
            if (chooser) {
              const clash = overlapping(variables, name, chosen, existing);
              if (clash) {
                const shared = chosen.length && (clash.workflows ?? []).length
                  ? (clash.workflows ?? []).filter((workflow) => chosen.includes(workflow))
                  : [];
                throw new Error(chosen.length === 0
                  ? `${name} already has a value for all workflows. Edit that one instead.`
                  : `${name} is already set ${coverage(shared)}. A workflow can get only one ${name} from the app: edit that one, or choose other workflows.`);
              }
            }
            const value = valueControl.value;
            if (isSecret && value === '' && !editing) {
              valueControl.setAttribute('aria-invalid', 'true');
              valueControl.focus();
              throw new Error('Enter the secret’s value.');
            }
            if (editing && existing.isSecret && !isSecret && value === '') {
              valueControl.setAttribute('aria-invalid', 'true');
              valueControl.focus();
              throw new Error('Type the value again to store it as plain text.');
            }
            if (editing) {
              const update = { workflows: chosen, isSecret, asFile };
              if (value !== '') update.value = value;
              await api.patch(`${base}/${seg(name)}${workflowQuery(existing.workflows ?? [])}`, update);
            } else {
              await api.put(`${base}/${seg(name)}`, isApp ? { value, isSecret, asFile, workflows: chosen } : { value, isSecret, asFile });
            }
            valueControl.value = '';
            toast(`Saved ${name}`, 'success');
            load();
            onChange?.();
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
    if (name.startsWith('CI_')) {
      return 'Names starting with CI_ are reserved: Hangar sets them for every job, as Xcode Cloud does.';
    }
    if (JOB_RESERVED_NAMES.includes(name)) {
      return `${name} is reserved: Hangar sets it for every job (also ${JOB_RESERVED_NAMES.filter((n) => n !== name).join(', ')}).`;
    }
    if (settingsOnly(name, isGlobal)) return `${name} is set in Settings.`;
    if (isGroup && name.startsWith('HANGAR_')) return `${name} can’t be in a group: set it in Settings or on the app.`;
    if (!isApp && variables.some((variable) => variable.name === name)) {
      return `${name} already exists. Use Replace to change its value.`;
    }
    return null;
  }

  load();
  return { element, reload: load };
}

/**
 * "All workflows" or "Only some workflows" with a checklist of the app's workflows. `known` is the list of names (null
 * when they could not be read, or empty: then the names are typed). A selected name that is not among them stays in
 * the list, flagged, so it can be unchecked. `value()` is the chosen names, sorted; empty means all workflows.
 */
function workflowChooser({ selected, known, subject }) {
  let mode = selected.length ? 'some' : 'all';
  const chosen = new Set(selected);
  const typed = h('input', {
    class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', placeholder: 'Beta, Release',
    value: selected.join(', '),
  });
  const names = known?.length ? [...new Set([...known, ...selected])].sort((a, b) => a.localeCompare(b)) : null;
  const extra = names
    ? h('ul', { class: 'wf-checklist', 'aria-label': 'Workflows' }, names.map((name) => checkRow({
      title: name,
      tag: known.includes(name) ? null : 'Not a workflow',
      tagWarning: true,
      checked: chosen.has(name),
      onChange: (checked) => { if (checked) chosen.add(name); else chosen.delete(name); },
    })))
    : field({
      label: 'Workflow names',
      hint: known ? 'This app has no workflows yet. Separate names with commas.' : 'The app’s workflows could not be read. Separate names with commas.',
      control: typed,
    });
  const element = h('fieldset', { class: 'variable-scope' },
    h('legend', { class: 'field-label' }, 'Workflows'),
    h('div', { class: 'variable-scope-choices' }));
  function render() {
    replaceChildren(element.lastChild, choiceCards({
      legend: 'Workflows',
      value: mode,
      options: [
        { value: 'all', title: 'All workflows', detail: subject === 'group' ? 'Every job of this app gets its variables.' : 'Every job of this app gets this variable.' },
        { value: 'some', title: 'Only some workflows', detail: subject === 'group' ? 'Only jobs of the workflows you choose get its variables.' : 'Replaces the one for all workflows in the workflows you choose.', extra },
      ],
      onChange: (next) => { mode = next; render(); },
    }));
  }
  render();
  return {
    element,
    value() {
      if (mode === 'all') return [];
      const list = names ? [...chosen] : typed.value.split(',');
      const result = normalizedWorkflows(list);
      if (result.length === 0) throw new Error('Choose at least one workflow, or All workflows.');
      return result;
    },
  };
}

/**
 * The groups an app links (Settings › Variable Groups), in precedence order, with Edit (its workflows), Unlink and
 * Link Group. `workflows` is a promise of the app's workflow names, as for `variablesEditor`.
 */
export function linkedGroupsEditor({ app, signal, workflows = Promise.resolve(null), onChange }) {
  const base = `/apps/${seg(app.slug)}/variable-groups`;
  const element = h('div', { class: 'variables linked-groups' });
  let links = [];
  let known = null;

  async function load() {
    replaceChildren(element, h('div', { class: 'list list-loading' }, spinner('Loading groups')));
    try {
      [links, known] = await Promise.all([api.get(base, { signal }), workflows.catch(() => null)]);
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
    const rows = links.map((link) => {
      const warning = unknownWorkflowsText(link.workflows, known, { group: true });
      const names = link.variables.map((variable) => variable.name);
      return h('li', { class: 'row variable-row' },
        h('div', { class: 'row-main' },
          h('div', { class: 'variable-name' }, link.name),
          h('div', { class: 'variable-meta' },
            h('span', { class: ['tag', link.workflows.length ? 'tag-workflows' : null] }, workflowsText(link.workflows)),
            h('span', { class: 'row-detail mono linked-group-names' }, names.length ? names.join(', ') : 'No variables yet')),
          warning ? h('p', { class: 'variable-warning' }, warning) : null),
        h('div', { class: 'row-actions' },
          button('Edit', { kind: 'plain', 'aria-label': `Edit the workflows of ${link.name}`, onClick: () => openSheet(link) }),
          button('Unlink', { kind: 'plain-destructive', 'aria-label': `Unlink ${link.name}`, onClick: () => unlink(link) })));
    });
    replaceChildren(element,
      h('ul', { class: 'list' },
        rows.length === 0
          ? h('li', { class: 'row' }, h('p', { class: 'row-detail' }, 'No groups linked.'))
          : rows,
        h('li', { class: 'row row-add' },
          h('button', { type: 'button', class: 'add-row-button', onClick: () => openSheet(null) },
            h('span', { class: 'add-row-plus', 'aria-hidden': 'true' }, plusIcon()),
            'Link Group'))));
  }

  async function unlink(link) {
    const names = link.variables.map((variable) => variable.name);
    const confirmed = await confirm({
      title: `Unlink ${link.name}?`,
      message: names.length
        ? `Jobs of this app stop getting ${listText(names)} from this group. The group itself stays in Settings.`
        : 'The group itself stays in Settings.',
      confirmLabel: 'Unlink',
      destructive: true,
    });
    if (!confirmed) return;
    try {
      await api.del(`${base}/${seg(link.groupID)}`);
      toast(`Unlinked ${link.name}`, 'success');
    } catch (error) {
      toast(error.message, 'error');
    }
    load();
    onChange?.();
  }

  /** Link Group (`existing` null): pick a group and its workflows; Edit: only the workflows. */
  async function openSheet(existing) {
    let groups = [];
    if (!existing) {
      try {
        groups = (await api.get('/variable-groups', { signal })).filter((group) => !links.some((link) => link.groupID === group.id));
      } catch (error) {
        if (error.code !== 'aborted') toast(error.message, 'error');
        return;
      }
    }
    if (!existing && groups.length === 0) {
      sheet({
        title: 'Link Group',
        body: h('p', { class: 'sheet-message' }, links.length
          ? 'Every variable group is linked already. Create another in Settings › Variable Groups.'
          : 'There are no variable groups yet. Create one in Settings › Variable Groups, then link it here.'),
        actions: [
          { label: 'Cancel', kind: 'cancel' },
          { label: 'Open Settings', kind: 'primary', onClick: () => navigate('/settings') },
        ],
      });
      return;
    }
    let picked = existing ? existing.groupID : groups[0].id;
    const picker = existing ? null : choiceCards({
      legend: 'Group',
      value: picked,
      options: groups.map((group) => ({
        value: group.id,
        title: group.name,
        detail: group.variables.length ? group.variables.map((variable) => variable.name).join(', ') : 'No variables yet',
      })),
      onChange: (value) => { picked = value; },
    });
    const chooser = workflowChooser({ selected: existing?.workflows ?? [], known, subject: 'group' });
    sheet({
      title: existing ? `Edit ${existing.name}` : 'Link Group',
      body: h('div', { class: 'form' },
        existing
          ? h('p', { class: 'sheet-message' }, `Choose which workflows of ${app.name} get the variables of ${existing.name}.`)
          : h('fieldset', { class: 'variable-scope' }, h('legend', { class: 'field-label' }, 'Group'), picker),
        chooser.element),
      actions: [
        { label: 'Cancel', kind: 'cancel' },
        {
          label: existing ? 'Save' : 'Link',
          kind: 'primary',
          onClick: async () => {
            const chosen = chooser.value();
            await api.put(`${base}/${seg(picked)}`, { workflows: chosen });
            const name = existing ? existing.name : groups.find((group) => group.id === picked)?.name;
            toast(existing ? `Saved ${name}` : `Linked ${name}`, 'success');
            load();
            onChange?.();
          },
        },
      ],
    });
  }

  load();
  return { element, reload: load };
}

/**
 * An app's share of the global secrets: plain global variables reach every app, a global secret only the apps that
 * chose it. One row per global secret with Receive or Stop Receiving, and first the GitHub token the app's jobs clone
 * with, which warns while it is the one in Settings (it reaches every repository that token can).
 */
export function globalSecretsEditor({ app, signal }) {
  const base = `/apps/${seg(app.slug)}/global-secrets`;
  const element = h('div', { class: 'variables global-secrets' });
  let state = { secrets: [], gitHubToken: 'none' };

  async function load() {
    replaceChildren(element, h('div', { class: 'list list-loading' }, spinner('Loading global secrets')));
    try {
      state = await api.get(base, { signal });
      render();
    } catch (error) {
      if (error.code === 'aborted') return;
      replaceChildren(element,
        h('div', { class: 'list inline-error' },
          h('p', { class: 'inline-error-message' }, error.message),
          button('Try Again', { kind: 'plain', onClick: load })));
    }
  }

  function tokenRow() {
    const own = state.gitHubToken === 'app';
    const global = state.gitHubToken === 'global';
    return h('li', { class: 'row variable-row' },
      h('div', { class: 'row-main' },
        h('div', { class: 'variable-name mono' }, 'HANGAR_GITHUB_TOKEN'),
        h('div', { class: 'variable-meta' },
          h('span', { class: ['tag', global ? 'tag-secret' : null] },
            own ? 'This App’s Own' : global ? 'From Settings' : 'None'),
          h('span', { class: 'row-detail' }, 'Clones the repository and its private packages')),
        global
          ? h('p', { class: 'variable-hint' },
            'The token in Settings reaches every repository it can read, and maybe write. Give this app its own '
            + 'fine-grained token instead: only this repository (and its private packages), Contents read-only. '
            + 'Add it under Environment as HANGAR_GITHUB_TOKEN.')
          : null));
  }

  function render() {
    const rows = state.secrets.map((secret) => h('li', { class: 'row variable-row' },
      h('div', { class: 'row-main' },
        h('div', { class: 'variable-name mono' }, secret.name),
        h('div', { class: 'variable-meta' },
          h('span', { class: ['tag', secret.granted ? 'tag-secret' : null] }, secret.granted ? 'Received' : 'Not Received'),
          secret.asFile ? h('span', { class: 'tag' }, 'File') : null)),
      h('div', { class: 'row-actions' },
        secret.granted
          ? button('Stop Receiving', {
            kind: 'plain-destructive', 'aria-label': `Stop giving ${secret.name} to ${app.name}`, onClick: () => revoke(secret),
          })
          : button('Receive', {
            kind: 'plain', 'aria-label': `Give ${secret.name} to ${app.name}`, onClick: () => grant(secret),
          }))));
    replaceChildren(element,
      h('ul', { class: 'list' },
        tokenRow(),
        rows.length === 0
          ? h('li', { class: 'row' }, h('p', { class: 'row-detail' }, 'No global secrets. Add them in Settings › Variables.'))
          : rows));
  }

  async function grant(secret) {
    try {
      await api.put(`${base}/${seg(secret.name)}`);
      toast(`${app.name} receives ${secret.name}`, 'success');
    } catch (error) {
      toast(error.message, 'error');
    }
    load();
  }

  async function revoke(secret) {
    const confirmed = await confirm({
      title: `Stop giving ${secret.name} to ${app.name}?`,
      message: `Jobs of ${app.name} no longer get ${secret.name}. The secret stays in Settings for the other apps.`,
      confirmLabel: 'Stop Receiving',
      destructive: true,
    });
    if (!confirmed) return;
    try {
      await api.del(`${base}/${seg(secret.name)}`);
      toast(`${app.name} no longer receives ${secret.name}`, 'success');
    } catch (error) {
      toast(error.message, 'error');
    }
    load();
  }

  load();
  return { element, reload: load };
}

/**
 * Settings' variable groups: each with its variables (the same editor as the global ones), the apps that link it,
 * Rename and Delete; New Group below them.
 */
export function variableGroupsEditor({ signal }) {
  const element = h('div', { class: 'variable-groups' });

  async function load() {
    let groups;
    try {
      groups = await api.get('/variable-groups', { signal });
    } catch (error) {
      if (error.code === 'aborted') return;
      replaceChildren(element,
        h('div', { class: 'list inline-error' },
          h('p', { class: 'inline-error-message' }, error.message),
          button('Try Again', { kind: 'plain', onClick: load })));
      return;
    }
    replaceChildren(element,
      groups.map((group) => groupBlock(group)),
      h('ul', { class: 'list' },
        groups.length === 0
          ? h('li', { class: 'row' }, h('p', { class: 'row-detail' }, 'No groups yet.'))
          : null,
        h('li', { class: 'row row-add' },
          h('button', { type: 'button', class: 'add-row-button', onClick: () => nameSheet(null) },
            h('span', { class: 'add-row-plus', 'aria-hidden': 'true' }, plusIcon()),
            'New Group'))));
  }

  function usedBy(group) {
    if (group.apps.length === 0) return 'Not linked to any app yet. Link it from an app’s Environment.';
    return `Linked by ${listText(group.apps.map((use) => (use.workflows.length ? `${use.name} (${listText(use.workflows)})` : use.name)))}`;
  }

  function groupBlock(group) {
    return h('div', { class: 'variable-group' },
      h('div', { class: 'variable-group-header' },
        h('div', { class: 'variable-group-title' },
          h('h3', { class: 'variable-group-name' }, group.name),
          h('p', { class: 'row-detail variable-group-uses' }, usedBy(group))),
        h('div', { class: 'row-actions' },
          button('Rename', { kind: 'plain', 'aria-label': `Rename ${group.name}`, onClick: () => nameSheet(group) }),
          button('Delete', { kind: 'plain-destructive', 'aria-label': `Delete ${group.name}`, onClick: () => remove(group) }))),
      variablesEditor({ scope: { group: group.id }, signal }).element);
  }

  async function remove(group) {
    const names = group.variables.map((variable) => variable.name);
    const apps = group.apps.map((use) => use.name);
    const what = names.length ? `its variables (${listText(names)})` : 'the group';
    const confirmed = await confirm({
      title: `Delete ${group.name}?`,
      message: apps.length
        ? `This deletes ${what}, and jobs of ${listText(apps)} stop getting them.`
        : `This deletes ${what}. No app links it.`,
      confirmLabel: 'Delete',
      destructive: true,
    });
    if (!confirmed) return;
    try {
      await api.del(`/variable-groups/${seg(group.id)}`);
      toast(`Deleted ${group.name}`, 'success');
    } catch (error) {
      toast(error.message, 'error');
    }
    load();
  }

  /** New Group (`existing` null) or Rename. */
  function nameSheet(existing) {
    const input = h('input', {
      class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', placeholder: 'Sentry', autofocus: true,
      value: existing?.name ?? '', maxlength: 64,
      onInput: () => input.removeAttribute('aria-invalid'),
    });
    sheet({
      title: existing ? `Rename ${existing.name}` : 'New Group',
      body: h('div', { class: 'form' },
        existing ? null : h('p', { class: 'sheet-message' }, 'A group holds variables that several apps use, such as a crash reporter’s token. Add its variables after creating it, then link it from each app.'),
        field({ label: 'Name', control: input })),
      submitOnEnter: true,
      actions: [
        { label: 'Cancel', kind: 'cancel' },
        {
          label: existing ? 'Rename' : 'Create',
          kind: 'primary',
          onClick: async () => {
            const name = input.value.trim();
            if (name === '') {
              input.setAttribute('aria-invalid', 'true');
              input.focus();
              throw new Error('Enter a name.');
            }
            if (existing) await api.patch(`/variable-groups/${seg(existing.id)}`, { name });
            else await api.post('/variable-groups', { name });
            toast(existing ? `Renamed to ${name}` : `Created ${name}`, 'success');
            load();
          },
        },
      ],
    });
  }

  load();
  return element;
}

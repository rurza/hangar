// Settings › Agent Access: API tokens for AI agents (`hangar mcp`). The secret is shown once, when the token is
// created; the list shows names, scopes and the first characters only.

import { api, seg } from '../api.js';
import { addLeaveGuard } from '../router.js';
import {
  button, confirm, copyText, field, h, plusIcon, relativeTime, replaceChildren, selectContents, sheet, spinner, toast,
} from '../ui.js';

/** What each scope allows; scopes nest. Mirrors `APITokenScope` and `APITokenPolicy` on the server. */
export const SCOPES = [
  { value: 'read', label: 'Read', detail: 'Look at apps, workflows, builds, logs, artifacts and machines.' },
  {
    value: 'deploy', label: 'Deploy',
    detail: 'Also start and cancel builds of an app’s own branches and tags, which can upload to TestFlight.',
  },
  {
    value: 'configure', label: 'Configure',
    detail: 'Also delete apps, store workflows and create TestFlight groups. Only you can add apps.',
  },
];

export function scopeLabel(value) {
  return SCOPES.find((scope) => scope.value === value)?.label ?? value;
}

/** Where the commands below keep the agent's token. */
const TOKEN_FILE = '~/.config/hangar/mcp-token';

/**
 * The commands that register `hangar mcp` with Claude Code for this server. The token never appears in them: the
 * first asks for it without echoing and saves it to a private file, and Claude Code gets the file's path. A token on
 * a command line would stay in the shell history and in Claude Code's settings.
 */
export function claudeCommand(origin) {
  return [
    `mkdir -p ~/.config/hangar && (umask 077; printf 'Paste the token: '; read -rs t; echo; printf '%s\\n' "$t" > ${TOKEN_FILE})`,
    `claude mcp add hangar --scope user --env HANGAR_SERVER=${origin} --env HANGAR_API_TOKEN_FILE="$HOME/.config/hangar/mcp-token" -- hangar mcp`,
  ].join('\n');
}

/** The token list with New Token and Revoke. `signal` (optional) cancels loading when the page is left. */
export function agentTokensEditor({ signal } = {}) {
  const element = h('div', { class: 'variables agent-tokens' });
  let tokens = [];

  async function load() {
    replaceChildren(element, h('div', { class: 'list list-loading' }, spinner('Loading tokens')));
    try {
      tokens = await api.get('/api-tokens', { signal });
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
    const rows = tokens.map((token) => h('li', { class: 'row variable-row' },
      h('div', { class: 'row-main' },
        h('div', { class: 'variable-name' }, token.name),
        h('div', { class: 'variable-meta' },
          h('span', { class: ['tag', token.scope === 'read' ? null : 'tag-secret'] }, scopeLabel(token.scope)),
          h('span', { class: 'row-detail mono' }, `${token.prefix}…`),
          h('span', { class: 'row-detail' },
            token.lastUsedAt ? `Used ${relativeTime(token.lastUsedAt)}` : `Created ${relativeTime(token.createdAt)}, never used`))),
      h('div', { class: 'row-actions' },
        button('Revoke', {
          kind: 'plain-destructive',
          'aria-label': `Revoke ${token.name}`,
          onClick: () => revoke(token),
        }))));
    replaceChildren(element,
      h('ul', { class: 'list' },
        rows.length === 0
          ? h('li', { class: 'row' }, h('p', { class: 'row-detail' }, 'No tokens yet.'))
          : rows,
        h('li', { class: 'row row-add' },
          h('button', { type: 'button', class: 'add-row-button', onClick: openCreateSheet },
            h('span', { class: 'add-row-plus', 'aria-hidden': 'true' }, plusIcon()),
            'New Token'))));
  }

  async function revoke(token) {
    const confirmed = await confirm({
      title: `Revoke ${token.name}?`,
      message: 'Agents using this token lose access at once. This cannot be undone.',
      confirmLabel: 'Revoke',
      destructive: true,
    });
    if (!confirmed) return;
    try {
      await api.del(`/api-tokens/${seg(token.id)}`);
      toast(`Revoked ${token.name}`, 'success');
    } catch (error) {
      toast(error.message, 'error');
    }
    load();
  }

  function openCreateSheet() {
    const nameInput = h('input', {
      class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', placeholder: 'Claude Code on MacBook',
      maxlength: 64, autofocus: true,
      onInput: () => nameInput.removeAttribute('aria-invalid'),
    });
    const hint = h('span');
    const scopeSelect = h('select', {
      class: 'select', 'aria-label': 'Scope',
      onChange: () => { hint.textContent = SCOPES.find((s) => s.value === scopeSelect.value).detail; },
    }, SCOPES.map((scope) => h('option', { value: scope.value }, scope.label)));
    scopeSelect.value = 'deploy';
    hint.textContent = SCOPES[1].detail;

    sheet({
      title: 'New Agent Token',
      submitOnEnter: true,
      body: h('div', { class: 'form' },
        field({ label: 'Name', hint: 'Which agent or Mac uses it, so you know what to revoke.', control: nameInput }),
        field({ label: 'Scope', hint, control: scopeSelect }),
        h('p', { class: 'card-note' },
          'No token can read or change variables, settings or machines, or manage tokens.')),
      actions: [
        { label: 'Cancel', kind: 'cancel' },
        {
          label: 'Create',
          kind: 'primary',
          onClick: async () => {
            const name = nameInput.value.trim();
            if (name === '') {
              nameInput.setAttribute('aria-invalid', 'true');
              nameInput.focus();
              throw new Error('Enter a name.');
            }
            const created = await api.post('/api-tokens', { name, scope: scopeSelect.value });
            load();
            setTimeout(() => openSecretSheet(created));
          },
        },
      ],
    });
  }

  load();
  return element;
}

/** Shows the new token's secret, once, with the command that connects Claude Code. */
function openSecretSheet({ token, secret }) {
  const command = claudeCommand(location.origin);
  const secretBlock = h('pre', { class: 'code-block token-block', tabindex: '0', 'aria-label': 'Token' }, h('code', null, secret));
  const commandBlock = h('pre', { class: 'code-block token-block', tabindex: '0', 'aria-label': 'Claude Code command' },
    h('code', null, command));
  let copied = false;

  async function copy(text, block, what) {
    if (await copyText(text)) {
      copied = true;
      toast(`Copied the ${what}`, 'success');
      return;
    }
    selectContents(block);
    toast(`The ${what} is selected. Press ⌘C to copy it.`, 'info');
  }

  const mayDismiss = () => copied || confirm({
    title: 'Close Without the Token?',
    message: 'You haven’t copied the token. It is not shown again; you would have to create a new one.',
    confirmLabel: 'Close',
    destructive: true,
  });
  const removeGuard = addLeaveGuard(mayDismiss);

  sheet({
    beforeDismiss: mayDismiss,
    onClose: removeGuard,
    title: `${token.name} Created`,
    body: h('div', { class: 'form token-sheet' },
      h('p', { class: 'token-warning', role: 'note' }, 'Save this token now; it is not shown again.'),
      h('div', { class: 'code-field' },
        h('div', { class: 'field-label-row' },
          h('span', { class: 'field-label' }, `Token (${scopeLabel(token.scope)})`),
          button('Copy Token', { kind: 'plain', class: 'button button-plain button-small', onClick: () => copy(secret, secretBlock, 'token') })),
        secretBlock),
      h('div', { class: 'code-field' },
        h('div', { class: 'field-label-row' },
          h('span', { class: 'field-label' }, 'Connect Claude Code'),
          button('Copy Command', { kind: 'plain', class: 'button button-plain button-small', onClick: () => copy(command, commandBlock, 'command') })),
        h('p', { class: 'field-hint' },
          'Run these in Terminal on the Mac where Claude Code runs, with hangar on its PATH. When asked, paste the '
          + 'token (Copy Token above): it is saved to a private file, so it stays out of your shell history. Other '
          + 'agents start hangar mcp with HANGAR_SERVER and HANGAR_API_TOKEN_FILE set.'),
        commandBlock)),
    actions: [{ label: 'Done', kind: 'primary' }],
  });
}

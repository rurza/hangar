// The Settings page: the App Store Connect key, the signing certificate, the GitHub token, agent tokens, global
// variables and About. The key and the token are write-only: the page shows whether they are set, never their
// values, and never pre-fills them.

import { api } from '../api.js';
import { button, card, confirm, field, h, page, replaceChildren, section, toast } from '../ui.js';
import { variableGroupsEditor, variablesEditor } from './variables.js';
import { agentTokensEditor } from './agent-tokens.js';
import { signingCard } from './signing.js';
import {
  ASC_KEYS_URL, appCountText, GH_NOTE, GITHUB_TOKEN_URL, externalLink, issuerField, keyDropZone, problem, withBusy,
} from './setup.js';

const GITHUB_TOKEN = 'HANGAR_GITHUB_TOKEN';

/** The `/settings` route. */
export async function settingsPage(params, context) {
  const { signal } = context;
  let status = await api.get('/settings', { signal });

  const about = card({ class: 'settings-card' });
  const asc = ascCard(() => status, (options) => refresh(asc, options));
  const github = githubCard(() => status, (options) => refresh(github, options));
  const signing = signingCard(() => status, { signal });
  const developmentKey = developmentKeyCard(() => status, (options) => refresh(developmentKey, options));

  /**
   * Reloads the status and redraws only `changed` (unless `redraw` is false), so a form open in the other card
   * keeps what was typed.
   */
  async function refresh(changed, { redraw = true } = {}) {
    try {
      status = await api.get('/settings', { signal });
    } catch (error) {
      if (error.code === 'aborted') return;
      toast(error.message, 'error');
    }
    if (redraw) changed.render();
    // Whether a team key is set decides whether Signing can offer Create.
    if (changed === asc) signing.render();
    renderAbout();
  }

  function renderAbout() {
    replaceChildren(about, h('dl', { class: 'facts' },
      fact('Version', status.version),
      fact('Server address', location.origin)));
  }

  asc.render();
  developmentKey.render();
  github.render();
  renderAbout();

  return page({
    title: 'Settings',
    actions: h('a', { href: '/setup', 'data-link': true, class: 'button button-secondary' }, 'Run Setup Again'),
  },
    section({
      title: 'App Store Connect',
      footer: 'Hangar uses the API key for build numbers, TestFlight, its signing certificate and development '
        + 'profiles. It is never a variable: workers use it for xcodebuild themselves, and no VM ever gets it.',
    }, asc.element),
    section({
      title: 'Signing',
      footer: 'VM builds sign development archives with this one certificate. Exports and TestFlight uploads stay '
        + 'signed by App Store Connect.',
    }, signing.element),
    section({
      title: 'Development Key',
      footer: 'Optional. VM builds never get the key above. A VM archive signs with development profiles Hangar '
        + 'provides; only when one is missing does its VM get this key, to let Xcode fetch it. Give it the Developer '
        + 'role: whoever controls a build’s code can copy it during that build.',
    }, developmentKey.element),
    section({
      title: 'GitHub',
      footer: 'Hangar reads your app repositories and their private Swift packages with it. Jobs of an app without its '
        + 'own HANGAR_GITHUB_TOKEN clone with it too: give each app a fine-grained, read-only token of its own.',
    }, github.element),
    advanced(),
    section({
      title: 'Agent Access',
      footer: 'Tokens let AI agents such as Claude Code use Hangar through hangar mcp. Each token is limited to its '
        + 'scope and can be revoked at any time.',
    }, agentTokensEditor({ signal })),
    section({
      title: 'Global Variables',
      footer: 'Every job of every app gets the plain ones. A secret reaches only the apps that receive it: choose them '
        + 'under Global Secrets on each app’s page. An app variable with the same name replaces one of these.',
    }, variablesEditor({ scope: 'global', signal }).element),
    section({
      title: 'Variable Groups',
      footer: 'Define variables once and use them in several apps: link a group from an app’s Environment, for all its '
        + 'workflows or only some. An app’s own variable with the same name replaces a group’s; a group’s replaces a '
        + 'global one.',
    }, variableGroupsEditor({ signal })),
    section({ title: 'About' }, about));
}

/** For build scripts: what reaches a job's environment and what never does. Most people never need it. */
function advanced() {
  return h('details', { class: 'disclosure' },
    h('summary', null, 'Advanced: Variables in Build Scripts'),
    h('p', { class: 'section-footer' },
      'Jobs get the GitHub token as HANGAR_GITHUB_TOKEN (an app’s own token, when it has one). '
      + 'The App Store Connect key is never in a job’s environment: workers use it for xcodebuild themselves, '
      + 'and a VM’s build never gets it.'));
}

/** "Not connected" with a grey dot: a card's state before it is set up. */
function notConnected() {
  return h('p', { class: 'card-headline settings-state' },
    h('span', { class: 'online-dot', 'aria-hidden': 'true' }), 'Not connected');
}

function fact(label, value) {
  return h('div', { class: 'fact' },
    h('dt', { class: 'fact-label' }, label),
    h('dd', { class: 'fact-value settings-value mono' }, value));
}

/** After a card switches between its status and its form, keeps focus in it instead of losing it to <body>. */
function focusFirst(element) {
  element.querySelector('input, button')?.focus();
}

/** Disables `buttons` while `work` runs; shows its error as a toast. Resolves to true when it succeeded. */
async function busy(buttons, work) {
  buttons.forEach((b) => { b.disabled = true; });
  try {
    await work();
    return true;
  } catch (error) {
    toast(error.message, 'error');
    return false;
  } finally {
    buttons.forEach((b) => { if (b.isConnected) b.disabled = false; });
  }
}

// MARK: App Store Connect

function ascCard(getStatus, refresh) {
  const element = card({ class: 'settings-card' });
  let editing = false;
  let counted = null; // { keyID, count } — the app count of the key on screen, -1 when it could not be read

  async function countApps(keyID) {
    counted = { keyID, count: null };
    try {
      counted = { keyID, count: (await api.get('/asc/apps')).length };
    } catch {
      counted = { keyID, count: -1 };
    }
    if (!editing) render();
  }

  function render() {
    const key = getStatus().appStoreConnect;
    if (!key || editing) {
      replaceChildren(element, form(key));
      return;
    }
    const team = key.kind === 'team';
    if (counted?.keyID !== key.keyID) countApps(key.keyID);
    const count = counted?.keyID === key.keyID ? counted.count : null;
    replaceChildren(element,
      h('p', { class: 'card-headline settings-state' },
        h('span', { class: 'online-dot online', 'aria-hidden': 'true' }),
        team ? 'Team key' : 'Individual key'),
      h('dl', { class: 'facts' },
        fact('Key ID', key.keyID),
        typeof count === 'number' && count >= 0 ? fact('Apps in App Store Connect', String(count)) : null,
        team && key.issuerID ? fact('Issuer ID', key.issuerID) : null),
      team ? null : h('p', { class: 'card-note' }, 'Builds sign with the Apple account signed in to Xcode on each worker Mac.'),
      h('div', { class: 'card-actions' },
        button('Replace Key', {
          onClick: () => {
            editing = true;
            render();
            focusFirst(element);
          },
        })));
  }

  /** The .p8 first: its name carries the key ID, and the Issuer ID is asked only when App Store Connect needs it. */
  function form(existing) {
    const slot = h('div', { class: 'form' });
    const cancel = existing
      ? button('Cancel', {
        kind: 'plain', class: 'button button-plain',
        onClick: () => {
          editing = false;
          render();
          focusFirst(element);
        },
      })
      : null;

    function showDrop() {
      replaceChildren(slot,
        existing ? null : notConnected(),
        h('p', { class: 'card-detail' },
          'Create a key in ', externalLink(ASC_KEYS_URL, 'App Store Connect › Users and Access › Integrations'),
          ' (an individual key, or a team key with the App Manager role) and add its .p8 file.'),
        keyDropZone(onKey),
        cancel ? h('div', { class: 'card-actions' }, cancel) : null);
    }

    function onKey({ keyID, text, name }) {
      const keyInput = h('input', {
        class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'characters',
        autocorrect: 'off', placeholder: 'ABC123DEFG', value: keyID ?? '',
        onInput: () => keyInput.removeAttribute('aria-invalid'),
      });
      const extra = h('div', { class: 'found-key-extra' });
      const save = button('Test & Save Key', { kind: 'primary', onClick: () => send(undefined, save) });
      async function send(issuerID, control) {
        const id = keyInput.value.trim().toUpperCase();
        if (!id) {
          keyInput.setAttribute('aria-invalid', 'true');
          keyInput.focus();
          return;
        }
        replaceChildren(extra);
        let result;
        try {
          // The server tests the key with App Store Connect and saves it only when it is accepted.
          result = await withBusy(control, 'Testing…', () => api.post('/settings/asc-key',
            { keyID: id, privateKey: text, ...(issuerID ? { issuerID } : {}) }));
        } catch (error) {
          if (error.code === 'issuer_required') {
            const issuer = issuerField((value, connect) => send(value, connect));
            replaceChildren(extra, issuer.element);
            issuer.focus();
          } else {
            replaceChildren(extra, problem(error.message));
            // Keeps what was typed, so a near miss is corrected rather than typed again.
            if (issuerID) extra.append(issuerField((value, connect) => send(value, connect), issuerID).element);
          }
          return;
        }
        counted = { keyID: result.keyID, count: result.appCount };
        toast(`Connected — ${appCountText(result.appCount)} in App Store Connect`, 'success');
        editing = false;
        await refresh();
        focusFirst(element);
      }
      function keyIDField() {
        return field({ label: 'Key ID', hint: 'The file name does not carry it; copy it from App Store Connect.', control: keyInput });
      }
      function keyIDLine() {
        const line = h('p', { class: 'card-note key-id-line' }, `Key ID ${keyID}, from the file name. `,
          h('button', {
            type: 'button', class: 'link-button',
            onClick: () => {
              line.replaceWith(field({ label: 'Key ID', control: keyInput }));
              keyInput.focus();
            },
          }, 'Edit'));
        return line;
      }
      replaceChildren(slot,
        h('p', { class: 'card-headline' }, name),
        // The file name carries the key ID; only a renamed file needs it typed, but it can still be corrected.
        keyID ? keyIDLine() : keyIDField(),
        extra,
        h('div', { class: 'card-actions' },
          button('Choose Another', { kind: 'plain', class: 'button button-plain', onClick: showDrop }),
          cancel,
          save));
      (keyID ? save : keyInput).focus();
    }

    showDrop();
    return slot;
  }

  return { element, render };
}

// MARK: Development key

/**
 * The optional second team key for VM archives whose development profiles Hangar could not provide. The server
 * tests it and refuses an individual key, an Admin key and its own key.
 */
function developmentKeyCard(getStatus, refresh) {
  const element = card({ class: 'settings-card' });
  let editing = false;

  function render() {
    const key = getStatus().developmentKey;
    if (!key || editing) {
      replaceChildren(element, form(key));
      return;
    }
    const remove = button('Remove', {
      kind: 'plain-destructive',
      onClick: async () => {
        const confirmed = await confirm({
          title: 'Remove the development key?',
          message: 'VM archives then sign only with the profiles Hangar provides; an iOS archive whose profile is '
            + 'missing fails before its VM starts. The key stays valid in App Store Connect until you revoke it there.',
          confirmLabel: 'Remove',
          destructive: true,
        });
        if (!confirmed) return;
        if (await busy([remove], () => api.del('/settings/development-key'))) {
          toast('Removed the development key', 'success');
          await refresh();
        }
      },
    });
    replaceChildren(element,
      h('p', { class: 'card-headline settings-state' },
        h('span', { class: 'online-dot online', 'aria-hidden': 'true' }), 'Team key, Developer role'),
      h('dl', { class: 'facts' }, fact('Key ID', key.keyID), key.issuerID ? fact('Issuer ID', key.issuerID) : null),
      h('div', { class: 'card-actions' },
        button('Replace Key', {
          onClick: () => {
            editing = true;
            render();
            focusFirst(element);
          },
        }),
        remove));
  }

  function form(existing) {
    const slot = h('div', { class: 'form' });
    const cancel = existing
      ? button('Cancel', { kind: 'plain', class: 'button button-plain', onClick: () => { editing = false; render(); } })
      : null;

    function showDrop() {
      replaceChildren(slot,
        existing ? null : h('p', { class: 'card-headline settings-state' },
          h('span', { class: 'online-dot', 'aria-hidden': 'true' }), 'Not set'),
        h('p', { class: 'card-detail' },
          'Create a team key with the Developer role and access to Certificates, Identifiers & Profiles in ',
          externalLink(ASC_KEYS_URL, 'App Store Connect › Users and Access › Integrations'), ', then add its .p8 file.'),
        keyDropZone(onKey),
        cancel ? h('div', { class: 'card-actions' }, cancel) : null);
    }

    function onKey({ keyID, text, name }) {
      const keyInput = h('input', {
        class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'characters',
        autocorrect: 'off', placeholder: 'ABC123DEFG', value: keyID ?? '',
      });
      const extra = h('div', { class: 'found-key-extra' });
      const issuer = issuerField(async (issuerID, control) => {
        const id = keyInput.value.trim().toUpperCase();
        if (!id) {
          keyInput.setAttribute('aria-invalid', 'true');
          keyInput.focus();
          return;
        }
        replaceChildren(extra);
        try {
          await withBusy(control, 'Testing…', () => api.post('/settings/development-key', { keyID: id, issuerID, privateKey: text }));
        } catch (error) {
          replaceChildren(extra, problem(error.message));
          return;
        }
        toast('Saved the development key', 'success');
        editing = false;
        await refresh();
        focusFirst(element);
      });
      replaceChildren(slot,
        h('p', { class: 'card-headline' }, name),
        field({ label: 'Key ID', control: keyInput }),
        issuer.element,
        extra,
        h('div', { class: 'card-actions' },
          button('Choose Another', { kind: 'plain', class: 'button button-plain', onClick: showDrop }),
          cancel));
      (keyID ? issuer : { focus: () => keyInput.focus() }).focus();
    }

    showDrop();
    return slot;
  }

  return { element, render };
}

// MARK: GitHub

function githubCard(getStatus, refresh) {
  const element = card({ class: 'settings-card' });
  let editing = false;

  function render() {
    const isSet = getStatus().githubTokenSet;
    const github = getStatus().github;
    if (!isSet || editing) {
      replaceChildren(element, form(isSet));
      return;
    }
    const replace = button('Replace Token', {
      onClick: () => {
        editing = true;
        render();
        focusFirst(element);
      },
    });
    const remove = button('Remove', {
      kind: 'plain-destructive', class: 'button button-plain-destructive',
      onClick: async () => {
        const confirmed = await confirm({
          title: 'Remove the GitHub token?',
          message: 'Builds of private repositories and private Swift packages fail until you set a new one.',
          confirmLabel: 'Remove',
          destructive: true,
        });
        if (!confirmed) return;
        if (await busy([replace, remove], () => api.del(`/variables/${GITHUB_TOKEN}`))) {
          toast('Removed the GitHub token', 'success');
          await refresh();
          focusFirst(element);
        }
      },
    });
    replaceChildren(element,
      h('p', { class: 'card-headline settings-state' },
        h('span', { class: 'online-dot online', 'aria-hidden': 'true' }),
        github?.login ? `Connected as ${github.login}` : 'Token set'),
      h('p', { class: 'card-note' }, github?.source === 'gh'
        ? GH_NOTE
        : 'The token cannot be shown. Replace it to use a different one.'),
      h('div', { class: 'card-actions' }, replace, remove));
  }

  function form(isSet) {
    const input = h('input', {
      class: 'input mono', type: 'password', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
      autocorrect: 'off', placeholder: isSet ? 'New token' : 'github_pat_…', 'data-1p-ignore': true, 'data-lpignore': 'true',
      onInput: () => input.removeAttribute('aria-invalid'),
      onKeydown: (event) => {
        if (event.key === 'Enter' && !event.isComposing) {
          event.preventDefault();
          save.click();
        }
      },
    });
    const message = h('div');
    const save = button('Save Token', {
      kind: 'primary',
      onClick: async () => {
        const token = input.value.trim();
        if (token === '') {
          input.setAttribute('aria-invalid', 'true');
          input.focus();
          toast('Enter the token.', 'error');
          return;
        }
        replaceChildren(message);
        let login;
        try {
          ({ login } = await withBusy(save, 'Checking…', () => api.post('/settings/github-token', { token })));
        } catch (error) {
          input.setAttribute('aria-invalid', 'true');
          replaceChildren(message, problem(error.message));
          return;
        }
        input.value = '';
        toast(`Connected to GitHub as ${login}`, 'success');
        editing = false;
        await refresh();
        focusFirst(element);
      },
    });
    const cancel = isSet
      ? button('Cancel', {
        kind: 'plain', class: 'button button-plain',
        onClick: () => {
          editing = false;
          render();
          focusFirst(element);
        },
      })
      : null;
    return h('div', { class: 'form' },
      isSet ? null : notConnected(),
      field({
        label: 'Personal access token',
        hint: h('span', null, externalLink(GITHUB_TOKEN_URL, 'Create a fine-grained token'),
          ' with Contents: Read-only. GitHub checks it before it is saved; it can’t be read back.'),
        control: input,
      }),
      message,
      h('div', { class: 'card-actions' }, cancel, save));
  }

  return { element, render };
}

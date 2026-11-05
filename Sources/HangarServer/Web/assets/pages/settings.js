// The Settings page: the App Store Connect key, the GitHub token, global variables and About. The key and the
// token are write-only: the page shows whether they are set, never their values, and never pre-fills them.

import { api } from '../api.js';
import { button, card, confirm, field, h, page, replaceChildren, section, toast } from '../ui.js';
import { variablesEditor } from './variables.js';
import { appCountText, GH_NOTE, GITHUB_TOKEN_URL, externalLink, problem, withBusy } from './setup.js';

const GITHUB_TOKEN = 'HANGAR_GITHUB_TOKEN';

/** The `/settings` route. */
export async function settingsPage(params, context) {
  const { signal } = context;
  let status = await api.get('/settings', { signal });

  const about = card({ class: 'settings-card' });
  const asc = ascCard(() => status, (options) => refresh(asc, options));
  const github = githubCard(() => status, (options) => refresh(github, options));

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
    renderAbout();
  }

  function renderAbout() {
    replaceChildren(about, h('dl', { class: 'facts' },
      fact('Version', status.version),
      fact('Server address', location.origin)));
  }

  asc.render();
  github.render();
  renderAbout();

  return page({
    title: 'Settings',
    actions: h('a', { href: '/setup', 'data-link': true, class: 'button button-secondary' }, 'Run Setup Again'),
  },
    section({
      title: 'App Store Connect',
      footer: 'Hangar uses the API key for build numbers and TestFlight. Jobs get it as HANGAR_ASC_KEY_ID, '
        + 'HANGAR_ASC_ISSUER_ID and HANGAR_ASC_KEY_PATH.',
    }, asc.element),
    section({
      title: 'GitHub',
      footer: 'A token that can read your app repositories and their private Swift packages. Jobs get it as HANGAR_GITHUB_TOKEN.',
    }, github.element),
    section({
      title: 'Global Variables',
      footer: 'Every job of every app gets these. An app variable with the same name replaces one of these.',
    }, variablesEditor({ scope: 'global', signal })),
    section({ title: 'About' }, about));
}

function cardTitle(text, trailing) {
  return h('div', { class: 'card-title-row' }, h('h3', { class: 'card-title' }, text), trailing);
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
      cardTitle('API Key'),
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

  function form(existing) {
    let keyText = null; // the .p8 contents, kept only until saved
    const keyIDInput = h('input', {
      class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'characters',
      autocorrect: 'off', placeholder: 'ABC123DEFG',
      onInput: () => keyIDInput.removeAttribute('aria-invalid'),
    });
    const issuerInput = h('input', {
      class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
      autocorrect: 'off', placeholder: '69a6de70-…',
    });
    const fileHint = h('span', null, 'The AuthKey_<Key ID>.p8 file you downloaded from App Store Connect.');
    const fileInput = h('input', {
      class: 'input file-input', type: 'file', accept: '.p8',
      onChange: () => readKey(),
    });

    function readKey() {
      keyText = null;
      fileInput.removeAttribute('aria-invalid');
      const file = fileInput.files?.[0];
      if (!file) return;
      const reader = new FileReader();
      reader.addEventListener('load', () => {
        const text = typeof reader.result === 'string' ? reader.result : '';
        if (!text.includes('BEGIN PRIVATE KEY')) {
          fileInput.value = '';
          fileInput.setAttribute('aria-invalid', 'true');
          toast(`${file.name} is not a private key (.p8) file.`, 'error');
          return;
        }
        keyText = text;
        // Fill in the key ID from the AuthKey_<ID>.p8 name when it is still empty.
        const id = /^AuthKey_([A-Za-z0-9]+)\.p8$/.exec(file.name)?.[1];
        if (id && keyIDInput.value.trim() === '') keyIDInput.value = id;
      });
      reader.addEventListener('error', () => {
        fileInput.value = '';
        toast(`${file.name} could not be read.`, 'error');
      });
      reader.readAsText(file);
    }

    const message = h('div');
    const save = button('Test & Save Key', {
      kind: 'primary',
      onClick: async () => {
        const keyID = keyIDInput.value.trim();
        const issuerID = issuerInput.value.trim();
        if (keyID === '') {
          keyIDInput.setAttribute('aria-invalid', 'true');
          keyIDInput.focus();
          toast('Enter the key ID.', 'error');
          return;
        }
        if (keyText === null) {
          fileInput.setAttribute('aria-invalid', 'true');
          fileInput.focus();
          toast('Choose the .p8 file.', 'error');
          return;
        }
        // The server tests the key with App Store Connect and saves it only when it is accepted.
        replaceChildren(message);
        let result;
        try {
          result = await withBusy(save, 'Testing…', () => api.post('/settings/asc-key',
            { keyID, privateKey: keyText, ...(issuerID ? { issuerID } : {}) }));
        } catch (error) {
          if (error.code === 'issuer_required') issuerInput.setAttribute('aria-invalid', 'true');
          replaceChildren(message, problem(error.message));
          if (error.code === 'issuer_required') issuerInput.focus();
          return;
        }
        counted = { keyID: result.keyID, count: result.appCount };
        keyText = null;
        fileInput.value = '';
        toast(`Connected — ${appCountText(result.appCount)} in App Store Connect`, 'success');
        editing = false;
        await refresh();
        focusFirst(element);
      },
    });
    const cancel = existing
      ? button('Cancel', {
        onClick: () => {
          keyText = null;
          editing = false;
          render();
          focusFirst(element);
        },
      })
      : null;

    return h('div', { class: 'form' },
      cardTitle(existing ? 'Replace API Key' : 'API Key'),
      existing ? null : h('p', { class: 'card-detail' },
        'Not set up. Create a key in App Store Connect under Users and Access › Integrations, with the App Manager role.'),
      h('div', { class: 'field-pair' },
        field({ label: 'Key ID', control: keyIDInput }),
        field({ label: 'Issuer ID', hint: 'Leave empty: Hangar asks for it if the key needs one.', control: issuerInput })),
      field({ label: 'Private key (.p8)', hint: fileHint, control: fileInput }),
      message,
      h('div', { class: 'card-actions' }, cancel, save));
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
    const replace = button('Replace', {
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
      cardTitle('Token'),
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
        onClick: () => {
          editing = false;
          render();
          focusFirst(element);
        },
      })
      : null;
    return h('div', { class: 'form' },
      cardTitle(isSet ? 'Replace Token' : 'Token'),
      isSet ? null : h('p', { class: 'card-detail' }, 'Not set.'),
      field({
        label: 'Personal access token',
        hint: h('span', null, externalLink(GITHUB_TOKEN_URL, 'Create a fine-grained token'),
          ' with Contents: Read-only. GitHub checks it before it is saved; it cannot be read back.'),
        control: input,
      }),
      message,
      h('div', { class: 'card-actions' }, cancel, save));
  }

  return { element, render };
}

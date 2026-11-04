// The Settings page: the App Store Connect key, the GitHub token, global variables and About. The key and the
// token are write-only: the page shows whether they are set, never their values, and never pre-fills them.

import { api } from '../api.js';
import { button, card, confirm, field, h, page, replaceChildren, section, toast } from '../ui.js';
import { variablesEditor } from './variables.js';

const ASC_KEY_ID = 'HANGAR_ASC_KEY_ID';
const ASC_ISSUER_ID = 'HANGAR_ASC_ISSUER_ID';
const ASC_KEY_PATH = 'HANGAR_ASC_KEY_PATH';
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

  return page({ title: 'Settings' },
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

  function render() {
    const key = getStatus().appStoreConnect;
    if (!key || editing) {
      replaceChildren(element, form(key));
      return;
    }
    const team = key.kind === 'team';
    replaceChildren(element,
      cardTitle('API Key'),
      h('p', { class: 'card-headline settings-state' },
        h('span', { class: 'online-dot online', 'aria-hidden': 'true' }),
        team ? 'Team key' : 'Individual key'),
      h('dl', { class: 'facts' },
        fact('Key ID', key.keyID),
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

    const save = button('Save Key', {
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
        // The key ID goes last: the key counts as configured once the ID and the key are both set, so until then
        // a half-saved key stays unconfigured (or keeps its old ID, which then fails visibly) instead of
        // pairing a new ID with an old key.
        let writes = 0;
        let failure = null;
        const buttons = [save, cancel].filter(Boolean);
        buttons.forEach((b) => { b.disabled = true; });
        try {
          await api.put(`/variables/${ASC_KEY_PATH}`, { value: keyText, isSecret: true, asFile: true });
          writes += 1;
          if (issuerID) await api.put(`/variables/${ASC_ISSUER_ID}`, { value: issuerID, isSecret: false, asFile: false });
          else await api.del(`/variables/${ASC_ISSUER_ID}`);
          writes += 1;
          await api.put(`/variables/${ASC_KEY_ID}`, { value: keyID, isSecret: false, asFile: false });
        } catch (error) {
          failure = error;
        } finally {
          buttons.forEach((b) => { if (b.isConnected) b.disabled = false; });
        }
        if (failure) {
          // The form stays as it is (the .p8 file too), so Save Key tries every write again.
          if (writes > 0) {
            toast(`Partially saved — save again. ${failure.message}`, 'error');
            // The status changes, but the form keeps what was entered so Save Key can run again.
            await refresh({ redraw: false });
          } else {
            toast(failure.message, 'error');
          }
          return;
        }
        keyText = null;
        fileInput.value = '';
        toast(`Saved the ${issuerID ? 'team' : 'individual'} key ${keyID}`, 'success');
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
        field({ label: 'Issuer ID', hint: 'Leave empty for an individual key.', control: issuerInput })),
      field({ label: 'Private key (.p8)', hint: fileHint, control: fileInput }),
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
        'Token set'),
      h('p', { class: 'card-note' }, 'The token cannot be shown. Replace it to use a different one.'),
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
        const saved = await busy([save, cancel].filter(Boolean),
          () => api.put(`/variables/${GITHUB_TOKEN}`, { value: token, isSecret: true, asFile: false }));
        if (!saved) return;
        input.value = '';
        toast('Saved the GitHub token', 'success');
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
        hint: 'A fine-grained token with read access to Contents. It cannot be read back after saving.',
        control: input,
      }),
      h('div', { class: 'card-actions' }, cancel, save));
  }

  return { element, render };
}

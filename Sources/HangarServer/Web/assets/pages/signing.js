// Settings › Signing: the one Apple Development certificate VM builds sign archives with. The page shows what the
// certificate says about itself, never the identity: the .p12 and its password stay on the server. Hangar creates a
// certificate only when this page's Create (or Renew) is confirmed, or `hangar signing create` is run.

import { api } from '../api.js';
import { button, card, confirm, field, h, replaceChildren, toast } from '../ui.js';
import { problem, withBusy } from './setup.js';

const dayFormat = new Intl.DateTimeFormat('en', { year: 'numeric', month: 'short', day: 'numeric' });
const DAY = 86_400_000;

/** "6 Nov 2027". */
function day(value) {
  return dayFormat.format(new Date(value));
}

function fact(label, value) {
  return h('div', { class: 'fact' },
    h('dt', { class: 'fact-label' }, label),
    h('dd', { class: 'fact-value settings-value' }, value));
}

function headline(dot, text) {
  return h('p', { class: 'card-headline settings-state' },
    h('span', { class: ['online-dot', dot], 'aria-hidden': 'true' }), text);
}

/** The headline for a stored certificate: its state and date. */
function stateLine(status) {
  const expires = status.identity.expiresAt;
  if (status.state === 'expired') return headline('failure', `Expired on ${day(expires)}`);
  if (status.state === 'expiring') {
    const days = Math.max(0, Math.ceil((new Date(expires) - Date.now()) / DAY));
    return headline('warning', `Expires ${days === 0 ? 'today' : `in ${days} ${days === 1 ? 'day' : 'days'}`}, on ${day(expires)}`);
  }
  return headline('online', `Active until ${day(expires)}`);
}

/**
 * The Signing card. `getSettings` gives the `/settings` status, for whether a team key is set: creating a certificate
 * needs one.
 */
export function signingCard(getSettings, { signal }) {
  const element = card({ class: 'settings-card' });
  let status = null;
  let importing = false;

  async function load() {
    try {
      status = await api.get('/signing', { signal });
    } catch (error) {
      if (error.code === 'aborted') return;
      replaceChildren(element, problem(error.message));
      return;
    }
    render();
  }

  function render() {
    if (!status) return;
    if (importing) {
      replaceChildren(element, importForm());
      return;
    }
    const teamKey = getSettings()?.appStoreConnect?.kind === 'team';
    const identity = status.identity;
    const actions = [];
    let note = null;

    if (!identity) {
      if (teamKey) actions.push(createButton('Create Hangar’s Signing Certificate', 'primary'));
      actions.push(button('Import .p12', { onClick: () => { importing = true; render(); focusFirst(); } }));
      if (!teamKey) note = 'Creating a certificate needs a team App Store Connect key (with an Issuer ID). You can still import a .p12 you have.';
      else if (!status.canCreate) note = status.createBlockedReason;
      replaceChildren(element,
        headline('', 'No certificate'),
        h('p', { class: 'card-detail' },
          'VM builds need an Apple Development certificate to sign archives, and wait until Hangar has one. '
          + 'Create it here once, or import one you already have.'),
        note ? h('p', { class: 'card-note' }, note) : null,
        h('div', { class: 'card-actions' }, actions));
      return;
    }

    const renewable = status.state === 'expiring' || status.state === 'expired';
    if (renewable && teamKey) actions.push(createButton('Renew', 'primary'));
    actions.push(removeButton());
    if (renewable && !teamKey) note = 'Renewing needs a team App Store Connect key. You can also remove this one and import another .p12.';
    else if (renewable && !status.canCreate) note = status.createBlockedReason;
    else if (!renewable) note = `Renewal opens 30 days before it expires, on ${day(new Date(identity.expiresAt) - 30 * DAY)}.`;
    else if (status.state === 'expired') note = 'VM archives wait until it is renewed or replaced.';
    const origin = identity.origin === 'created'
      ? `Created by Hangar on ${day(identity.createdAt)}`
      : `Imported on ${day(identity.createdAt)}`;
    replaceChildren(element,
      stateLine(status),
      h('dl', { class: 'facts' },
        fact('Certificate', identity.name),
        identity.teamID ? fact('Team ID', identity.teamID) : null,
        fact('Origin', origin)),
      note ? h('p', { class: 'card-note' }, note) : null,
      h('div', { class: 'card-actions' }, actions));
  }

  function focusFirst() {
    element.querySelector('input, button')?.focus();
  }

  function createButton(label, kind) {
    const control = button(label, {
      kind,
      disabled: !status.canCreate,
      onClick: async () => {
        const renewing = Boolean(status.identity);
        const revokes = renewing && status.identity.origin === 'created';
        const confirmed = await confirm({
          title: renewing ? 'Renew the signing certificate?' : 'Create Hangar’s signing certificate?',
          message: (renewing
            ? 'Hangar creates a new Apple Development certificate through your App Store Connect key and switches to it. '
              + (revokes ? 'Then it revokes the old one it created, and only that one. ' : 'Your imported certificate is not revoked. ')
            : 'Hangar creates one Apple Development certificate for your team through your App Store Connect key, '
              + 'and keeps it encrypted on this server. VM builds sign development archives with it. ')
            + 'It doesn’t affect your live apps, your other certificates or distribution signing, and Hangar creates '
            + 'no other until it is within 30 days of expiring.',
          confirmLabel: renewing ? 'Renew' : 'Create Certificate',
        });
        if (!confirmed) return;
        let result;
        try {
          result = await withBusy(control, renewing ? 'Renewing…' : 'Creating…', () => api.post('/signing/certificate'));
        } catch (error) {
          toast(error.message, 'error');
          return;
        }
        status = result.status;
        render();
        toast(renewing ? 'Renewed the signing certificate' : 'Created Hangar’s signing certificate', 'success');
        if (result.revokeProblem) toast(result.revokeProblem, 'error');
        focusFirst();
      },
    });
    return control;
  }

  function removeButton() {
    const control = button('Remove', {
      kind: 'plain-destructive', class: 'button button-plain-destructive',
      onClick: async () => {
        const confirmed = await confirm({
          title: 'Remove the signing certificate?',
          message: 'Hangar deletes its stored copy, and VM archives wait until there is another. The certificate is '
            + `not revoked: it stays valid at Apple until ${day(status.identity.expiresAt)}. Revoke it in the Apple `
            + 'Developer website if you no longer need it.',
          confirmLabel: 'Remove',
          destructive: true,
        });
        if (!confirmed) return;
        try {
          control.disabled = true;
          status = await api.del('/signing');
        } catch (error) {
          toast(error.message, 'error');
          if (control.isConnected) control.disabled = false;
          return;
        }
        render();
        toast('Removed the signing certificate', 'success');
        focusFirst();
      },
    });
    return control;
  }

  /** A .p12 and its password; the server checks both and packs the identity under a password of its own. */
  function importForm() {
    let file = null; // { name, base64 }
    const fileInput = h('input', {
      class: 'visually-hidden', type: 'file', accept: '.p12,.pfx,application/x-pkcs12',
      onChange: () => read(fileInput.files?.[0]),
    });
    const title = h('span', { class: 'drop-zone-title' }, 'Drop your .p12 here');
    const detail = h('span', { class: 'drop-zone-detail' }, 'or click to choose the file');
    const zone = h('label', { class: 'drop-zone' }, fileInput, title, detail);
    const password = h('input', {
      class: 'input', type: 'password', autocomplete: 'off', spellcheck: 'false', 'data-1p-ignore': true,
      'data-lpignore': 'true',
      onKeydown: (event) => {
        if (event.key === 'Enter' && !event.isComposing) {
          event.preventDefault();
          save.click();
        }
      },
    });
    const message = h('div');

    function read(chosen) {
      if (!chosen) return;
      const reader = new FileReader();
      reader.addEventListener('load', () => {
        const bytes = new Uint8Array(reader.result);
        let binary = '';
        for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
        file = { name: chosen.name, base64: btoa(binary) };
        replaceChildren(title, chosen.name);
        replaceChildren(detail, 'Click to choose another file');
        password.focus();
      });
      reader.addEventListener('error', () => toast(`${chosen.name} could not be read.`, 'error'));
      reader.readAsArrayBuffer(chosen);
    }
    zone.addEventListener('dragover', (event) => {
      event.preventDefault();
      zone.classList.add('drop-zone-over');
    });
    zone.addEventListener('dragleave', () => zone.classList.remove('drop-zone-over'));
    zone.addEventListener('drop', (event) => {
      event.preventDefault();
      zone.classList.remove('drop-zone-over');
      read(event.dataTransfer?.files?.[0]);
    });

    const save = button('Import', {
      kind: 'primary',
      onClick: async () => {
        if (!file) {
          toast('Choose the .p12 file first.', 'error');
          return;
        }
        replaceChildren(message);
        try {
          status = await withBusy(save, 'Checking…', () => api.post('/signing/import', { p12: file.base64, password: password.value }));
        } catch (error) {
          replaceChildren(message, problem(error.message));
          return;
        }
        password.value = '';
        importing = false;
        render();
        toast('Imported the signing certificate', 'success');
        focusFirst();
      },
    });
    const cancel = button('Cancel', {
      kind: 'plain', class: 'button button-plain',
      onClick: () => { importing = false; render(); focusFirst(); },
    });
    return h('div', { class: 'form' },
      h('p', { class: 'card-detail' },
        'Export your Apple Development certificate with its private key from Keychain Access as a .p12. '
        + 'Hangar creates nothing at Apple when you import one.'),
      zone,
      field({ label: '.p12 password', hint: 'The password you chose when you exported it. Hangar doesn’t keep it.', control: password }),
      message,
      h('div', { class: 'card-actions' }, cancel, save));
  }

  load();
  return { element, render, load };
}

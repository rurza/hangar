// Settings › Access: which Tailscale accounts count as the owner. The owner's devices use Hangar without a token;
// everything else (scripts on loopback, agents) needs an API token.

import { api } from '../api.js';
import { button, card, field, h, replaceChildren, toast } from '../ui.js';

/** "alice@github, bob@github" → ["alice@github", "bob@github"]. */
export function parseLogins(text) {
  return text.split(/[\s,]+/).map((login) => login.trim()).filter(Boolean);
}

/** The Access card: who is viewing, and the allowed logins with Change. `signal` cancels loading. */
export function accessCard({ signal } = {}) {
  const element = card({ class: 'settings-card access-card' });
  let status = null;
  let editing = false;

  async function load() {
    try {
      status = await api.get('/access', { signal });
    } catch (error) {
      if (error.code === 'aborted') return;
      replaceChildren(element, h('p', { class: 'inline-error-message' }, error.message));
      return;
    }
    render();
  }

  function viewer() {
    if (status.viewerLogin) return `You are signed in to Tailscale as ${status.viewerLogin}.`;
    if (status.viewerToken) return `You are using the owner token “${status.viewerToken}”.`;
    return null;
  }

  function summary() {
    const logins = status.allowedLogins;
    let headline;
    if (logins.length === 0) headline = 'No Tailscale account is allowed';
    else if (logins.length === 1) headline = logins[0];
    else headline = `${logins.length} Tailscale accounts`;
    const note = status.configured
      ? 'Set here. Reset goes back to the account that owns the server Mac.'
      : status.serverNodeTagged
        ? 'The server Mac’s tailnet node is tagged, so it has no owner: add your account.'
        : 'The account that owns the server Mac. Devices signed in to it open Hangar without a token.';
    return [
      h('p', { class: 'card-headline settings-state' },
        h('span', { class: ['online-dot', logins.length ? 'online' : null], 'aria-hidden': 'true' }), headline),
      logins.length > 1 ? h('ul', { class: 'access-logins' }, ...logins.map((login) => h('li', { class: 'mono' }, login))) : null,
      h('p', { class: 'card-note' }, note),
      viewer() ? h('p', { class: 'card-note' }, viewer()) : null,
    ];
  }

  function render() {
    if (editing) {
      replaceChildren(element, form());
      return;
    }
    const change = button('Change', {
      onClick: () => {
        editing = true;
        render();
        element.querySelector('input')?.focus();
      },
    });
    const reset = status.configured
      ? button('Reset', { kind: 'plain', class: 'button button-plain', onClick: () => save([], reset) })
      : null;
    replaceChildren(element, ...summary(), h('div', { class: 'card-actions' }, reset, change));
  }

  async function save(logins, control) {
    control.disabled = true;
    try {
      status = await api.put('/access', { allowedLogins: logins });
    } catch (error) {
      toast(error.message, 'error');
      return false;
    } finally {
      if (control.isConnected) control.disabled = false;
    }
    toast(logins.length ? 'Saved the allowed accounts' : 'Back to the server Mac’s account', 'success');
    editing = false;
    render();
    return true;
  }

  function form() {
    const input = h('input', {
      class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
      autocorrect: 'off', placeholder: 'alice@github', value: status.allowedLogins.join(', '),
      onKeydown: (event) => {
        if (event.key === 'Enter' && !event.isComposing) {
          event.preventDefault();
          submit.click();
        }
      },
    });
    const submit = button('Save', {
      kind: 'primary',
      onClick: () => {
        const logins = parseLogins(input.value);
        if (logins.length === 0) {
          input.setAttribute('aria-invalid', 'true');
          toast('Enter at least one account, or use Reset.', 'error');
          return;
        }
        save(logins, submit);
      },
    });
    const cancel = button('Cancel', {
      kind: 'plain', class: 'button button-plain',
      onClick: () => {
        editing = false;
        render();
      },
    });
    return h('div', { class: 'form' },
      field({
        label: 'Tailscale accounts',
        hint: 'Separate them with commas. Keep your own, or this device loses access.',
        control: input,
      }),
      h('div', { class: 'card-actions' }, cancel, submit));
  }

  replaceChildren(element, h('p', { class: 'card-note' }, 'Loading…'));
  load();
  return element;
}

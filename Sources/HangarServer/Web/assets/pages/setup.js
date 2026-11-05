// The Setup page (/setup): App Store Connect, GitHub and a build Mac, each filled in from what Hangar finds on the
// Mac it runs on — API key files in Apple's key folders and Downloads, the GitHub CLI's login, this Mac itself.
// The empty Apps page leads here until all three are done; Settings links back with "Run Setup Again". Key
// contents and tokens never come back from the server: the page sees paths, key IDs and logins only.

import { api, events } from '../api.js';
import { navigate } from '../router.js';
import {
  button, card, field, h, page, relativeTime, replaceChildren, spinner, toast,
} from '../ui.js';
import { machineWidget, openAddMacSheet, openAddMachineSheet, removeMachine } from './machines.js';

export const ASC_KEYS_URL = 'https://appstoreconnect.apple.com/access/integrations/api';
export const GITHUB_TOKEN_URL = 'https://github.com/settings/personal-access-tokens/new?name=Hangar&description=Hangar%20builds&contents=read';
const INSTALL_POLL_MS = 700;
const SKIP_KEY = 'hangar.setupSkipped';

/** Whether setup still has a step to do: no App Store Connect key, no GitHub token or no machine. */
export function setupIncomplete(status) {
  return !status.appStoreConnect || !status.github || status.machines === 0;
}

/** The user chose "Skip for Now" in this tab: the empty Apps page stops sending them here. */
export function setupSkipped() {
  try {
    return sessionStorage.getItem(SKIP_KEY) === '1';
  } catch {
    return false;
  }
}

function skipSetup() {
  try {
    sessionStorage.setItem(SKIP_KEY, '1');
  } catch {
    // Without storage the Apps page offers setup again; nothing is lost.
  }
}

// MARK: Shared pieces

/** An external link that opens in a new tab. */
export function externalLink(href, text) {
  return h('a', { href, target: '_blank', rel: 'noopener noreferrer' }, text);
}

/** "✓" in a green circle and `text`: a finished step's headline. */
export function doneLine(text) {
  return h('p', { class: 'setup-done' },
    h('span', { class: 'setup-done-icon', 'aria-hidden': 'true' }, '✓'),
    h('span', null, text));
}

/** An inline problem with what to do about it. */
export function problem(message) {
  return h('p', { class: 'setup-problem', role: 'alert' }, message);
}

/** "11 apps" / "1 app". */
export function appCountText(count) {
  return `${count} ${count === 1 ? 'app' : 'apps'}`;
}

/** Runs `work` with `control` disabled and showing `busyLabel`; restores the label afterwards. */
export async function withBusy(control, busyLabel, work) {
  const label = control.textContent;
  control.disabled = true;
  replaceChildren(control, spinner(busyLabel), h('span', null, busyLabel));
  control.classList.add('button-busy');
  try {
    return await work();
  } finally {
    control.classList.remove('button-busy');
    if (control.isConnected) {
      control.disabled = false;
      replaceChildren(control, label);
    }
  }
}

/**
 * The Issuer ID field App Store Connect asks for when a key is a team key. `onSubmit(issuerID)` runs on Connect
 * or Return.
 */
export function issuerField(onSubmit) {
  const input = h('input', {
    class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
    autocorrect: 'off', placeholder: '69a6de70-03db-47e3-e053-5b8c7c11a4d1',
    onInput: () => input.removeAttribute('aria-invalid'),
    onKeydown: (event) => {
      if (event.key === 'Enter' && !event.isComposing) {
        event.preventDefault();
        connect.click();
      }
    },
  });
  const connect = button('Connect', {
    kind: 'primary',
    onClick: () => {
      const issuerID = input.value.trim();
      if (!issuerID) {
        input.setAttribute('aria-invalid', 'true');
        input.focus();
        return;
      }
      onSubmit(issuerID, connect);
    },
  });
  const element = h('div', { class: 'setup-issuer' },
    field({
      label: 'Issuer ID',
      hint: h('span', null, 'This is a team key, so it needs the Issuer ID shown above the keys in ',
        externalLink(ASC_KEYS_URL, 'App Store Connect › Users and Access › Integrations'), '.'),
      control: input,
    }),
    h('div', { class: 'card-actions' }, connect));
  return { element, focus: () => input.focus() };
}

/**
 * A drop zone for an `AuthKey_<ID>.p8` file that also opens the file picker. `onKey({ keyID, text, name })` gets
 * the key; `keyID` is null when the file name does not carry it.
 */
export function keyDropZone(onKey) {
  const input = h('input', {
    class: 'visually-hidden', type: 'file', accept: '.p8',
    onChange: () => read(input.files?.[0]),
  });
  const zone = h('label', { class: 'drop-zone' },
    input,
    h('span', { class: 'drop-zone-title' }, 'Drop your AuthKey_….p8 here'),
    h('span', { class: 'drop-zone-detail' }, 'or click to choose the file'));

  function read(file) {
    if (!file) return;
    const reader = new FileReader();
    reader.addEventListener('load', () => {
      input.value = '';
      const text = typeof reader.result === 'string' ? reader.result : '';
      if (!text.includes('PRIVATE KEY')) {
        toast(`${file.name} is not an App Store Connect API key (.p8).`, 'error');
        return;
      }
      const keyID = /^AuthKey_([A-Za-z0-9]+)(?: ?\(\d+\))?\.p8$/.exec(file.name)?.[1]?.toUpperCase() ?? null;
      onKey({ keyID, text, name: file.name });
    });
    reader.addEventListener('error', () => toast(`${file.name} could not be read.`, 'error'));
    reader.readAsText(file);
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
  return zone;
}

// MARK: Page

/** The `/setup` route. */
export async function setupPage(params, context) {
  const { signal } = context;
  let status = await api.get('/setup', { signal });

  const finish = h('div', { class: 'setup-finish' });
  const asc = ascStep(() => status, onChange, signal);
  const github = githubStep(() => status, onChange, signal);
  const machines = machinesStep(() => status, onChange, context);

  async function onChange() {
    try {
      status = await api.get('/setup', { signal });
    } catch (error) {
      if (error.code !== 'aborted') toast(error.message, 'error');
      return;
    }
    asc.update();
    github.update();
    machines.update();
    renderFinish();
  }

  function renderFinish() {
    const remaining = [!status.appStoreConnect, !status.github, status.machines === 0].filter(Boolean).length;
    const ready = remaining === 0;
    const go = button(ready && status.apps === 0 ? 'You’re Ready — Add Your First App' : 'Go to Apps', {
      kind: ready ? 'primary' : 'secondary',
      class: ['button', ready ? 'button-primary' : 'button-secondary', 'setup-go'],
      onClick: () => {
        if (!ready) skipSetup();
        navigate(ready && status.apps === 0 ? '/?add=1' : '/');
      },
    });
    replaceChildren(finish,
      h('p', { class: 'card-detail' }, ready
        ? 'Everything Hangar needs is set up.'
        : `${remaining} ${remaining === 1 ? 'step' : 'steps'} left. You can finish ${remaining === 1 ? 'it' : 'them'} later from Settings.`),
      ready ? go : button('Skip for Now', {
        kind: 'plain', class: 'button button-plain',
        onClick: () => {
          skipSetup();
          navigate('/');
        },
      }));
  }

  asc.update();
  github.update();
  machines.update();
  renderFinish();

  return page({
    title: 'Set Up Hangar',
    subtitle: 'Hangar looked around this Mac for what it needs. Most of it is one click.',
  },
  h('ol', { class: 'setup-steps' },
    h('li', null, asc.element),
    h('li', null, github.element),
    h('li', null, machines.element)),
  finish);
}

/** A step's card: number (a ✓ once done), title and body. */
function stepCard(number, title) {
  const badge = h('span', { class: 'step-badge', 'aria-hidden': 'true' }, String(number));
  const state = h('span', { class: 'visually-hidden' });
  const body = h('div', { class: 'step-body' });
  const element = card({ class: 'setup-step' },
    h('div', { class: 'step-head' }, badge, h('h2', { class: 'step-title' }, title, state)),
    body);
  return {
    element,
    body,
    setDone(done) {
      badge.textContent = done ? '✓' : String(number);
      badge.classList.toggle('step-badge-done', done);
      state.textContent = done ? ' (done)' : '';
    },
  };
}

// MARK: 1. App Store Connect

function ascStep(getStatus, onChange, signal) {
  const step = stepCard(1, 'App Store Connect');
  let replacing = false;
  let appCount = null; // from the test that connected the key, else looked up once
  let found = null; // FoundASCKey[] once scanned
  let scanError = null;

  async function scan() {
    try {
      found = await api.get('/setup/asc-keys', { signal });
      scanError = null;
    } catch (error) {
      if (error.code === 'aborted') return;
      found = [];
      scanError = error.message;
    }
    update();
  }

  async function countApps() {
    try {
      const apps = await api.get('/asc/apps', { signal });
      appCount = apps.length;
    } catch {
      appCount = -1;
    }
    update();
  }

  function update() {
    const key = getStatus().appStoreConnect;
    step.setDone(Boolean(key));
    if (key && !replacing) {
      if (appCount === null) countApps();
      replaceChildren(step.body,
        doneLine(appCount === null || appCount < 0
          ? `Connected with key ${key.keyID}`
          : `Connected — ${appCountText(appCount)} in App Store Connect`),
        h('p', { class: 'card-note' }, key.kind === 'team'
          ? `Team key ${key.keyID}. Builds sign with the key (cloud-managed signing).`
          : `Individual key ${key.keyID}. Builds sign with the Apple account signed in to Xcode on each build Mac.`),
        h('div', { class: 'card-actions' }, button('Use a Different Key', {
          kind: 'plain', class: 'button button-plain button-small',
          onClick: () => {
            replacing = true;
            update();
          },
        })));
      return;
    }
    // Only a browser on the server's Mac may use the keys found there; anyone else chooses the file.
    if (!getStatus().viewerIsLocal) found = [];
    if (found === null) {
      replaceChildren(step.body, h('p', { class: 'setup-looking' }, spinner('Looking'), 'Looking for API keys on this Mac…'));
      scan();
      return;
    }
    replaceChildren(step.body,
      h('p', { class: 'card-detail' }, 'Hangar reads build numbers and uploads to TestFlight with an App Store Connect API key.'),
      found.length ? foundKeys(found) : null,
      scanError ? problem(`Looking for keys failed: ${scanError}`) : null,
      uploadKey(found.length > 0),
      replacing ? h('div', { class: 'card-actions' }, button('Cancel', {
        kind: 'plain', class: 'button button-plain button-small',
        onClick: () => {
          replacing = false;
          update();
        },
      })) : null);
  }

  function connected(result) {
    appCount = result.appCount;
    replacing = false;
    toast(`Connected — ${appCountText(result.appCount)} in App Store Connect`, 'success');
    onChange();
  }

  function foundKeys(keys) {
    const list = h('ul', { class: 'found-keys' });
    keys.slice(0, 5).forEach((key, index) => {
      const slot = h('div', { class: 'found-key-extra' });
      const folder = key.displayPath.slice(0, key.displayPath.lastIndexOf('/')) || '/';
      const use = button('Use This Key', {
        kind: index === 0 ? 'primary' : 'secondary',
        class: ['button', index === 0 ? 'button-primary' : 'button-secondary', 'button-small'],
        onClick: () => tryKey(undefined, use),
      });
      async function tryKey(issuerID, control) {
        replaceChildren(slot);
        try {
          const result = await withBusy(control, 'Testing…',
            () => api.post('/setup/asc-keys/use', issuerID ? { path: key.path, issuerID } : { path: key.path }));
          connected(result);
        } catch (error) {
          if (error.code === 'issuer_required') {
            const issuer = issuerField((value, connect) => tryKey(value, connect));
            replaceChildren(slot, issuer.element);
            issuer.focus();
          } else {
            replaceChildren(slot, problem(error.message));
            if (issuerID) {
              const issuer = issuerField((value, connect) => tryKey(value, connect));
              slot.append(issuer.element);
            }
          }
        }
      }
      list.append(h('li', { class: 'found-key' },
        h('div', { class: 'found-key-row' },
          h('div', { class: 'found-key-text' },
            h('p', { class: 'found-key-name mono' }, `AuthKey_${key.keyID}.p8`),
            h('p', { class: 'card-note' }, `in ${folder} · ${relativeTime(key.modifiedAt)}`)),
          use),
        slot));
    });
    return h('div', { class: 'found-keys-group' },
      h('p', { class: 'card-headline' }, keys.length === 1 ? 'Found a key on this Mac' : `Found ${keys.length} keys on this Mac`),
      list);
  }

  function uploadKey(collapsed) {
    const slot = h('div', { class: 'upload-key' });
    const howTo = h('div', { class: 'setup-howto' },
      h('p', { class: 'card-note' },
        'No key yet? In ', externalLink(ASC_KEYS_URL, 'App Store Connect › Users and Access › Integrations'),
        ', create a key and download its .p8 file. Individual keys work; a Team key with the App Manager role also works.'));

    function showDrop() {
      replaceChildren(slot, keyDropZone(onKey), howTo);
    }

    function onKey({ keyID, text, name }) {
      const keyInput = h('input', {
        class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'characters',
        autocorrect: 'off', placeholder: 'ABC123DEFG', value: keyID ?? '',
      });
      const extra = h('div', { class: 'found-key-extra' });
      const connect = button('Connect', { kind: 'primary', onClick: () => send(undefined, connect) });
      async function send(issuerID, control) {
        const id = keyInput.value.trim().toUpperCase();
        if (!id) {
          keyInput.setAttribute('aria-invalid', 'true');
          keyInput.focus();
          return;
        }
        replaceChildren(extra);
        try {
          const result = await withBusy(control, 'Testing…', () => api.post('/settings/asc-key',
            { keyID: id, privateKey: text, ...(issuerID ? { issuerID } : {}) }));
          connected(result);
        } catch (error) {
          if (error.code === 'issuer_required') {
            const issuer = issuerField((value, button2) => send(value, button2));
            replaceChildren(extra, issuer.element);
            issuer.focus();
          } else {
            replaceChildren(extra, problem(error.message));
            if (issuerID) extra.append(issuerField((value, button2) => send(value, button2)).element);
          }
        }
      }
      replaceChildren(slot,
        h('p', { class: 'card-headline' }, name),
        keyID ? null : field({ label: 'Key ID', hint: 'The file name does not carry it; copy it from App Store Connect.', control: keyInput }),
        h('div', { class: 'card-actions' },
          button('Choose Another', { kind: 'plain', class: 'button button-plain', onClick: showDrop }),
          connect),
        extra);
      if (keyID) connect.click();
      else keyInput.focus();
    }

    if (collapsed) {
      replaceChildren(slot, button('Choose a Different .p8 File…', {
        kind: 'plain', class: 'button button-plain button-small', onClick: showDrop,
      }));
    } else {
      showDrop();
    }
    return slot;
  }

  return { element: step.element, update };
}

// MARK: 2. GitHub

/** What copying the gh login means, shown wherever it is offered or in use. */
export const GH_NOTE = 'Hangar copies the GitHub CLI’s token: an OAuth token with your gh scopes. '
  + 'If you run gh auth logout, Hangar keeps working until you replace it.';

/**
 * The paste-a-token form. `onSaved(login)` runs once GitHub accepted the token and Hangar saved it.
 */
export function tokenForm(onSaved, { onCancel } = {}) {
  const input = h('input', {
    class: 'input mono', type: 'password', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
    autocorrect: 'off', placeholder: 'github_pat_…', 'data-1p-ignore': true, 'data-lpignore': 'true',
    onInput: () => input.removeAttribute('aria-invalid'),
    onKeydown: (event) => {
      if (event.key === 'Enter' && !event.isComposing) {
        event.preventDefault();
        save.click();
      }
    },
  });
  const message = h('div');
  const save = button('Connect', {
    kind: 'primary',
    onClick: async () => {
      const token = input.value.trim();
      if (!token) {
        input.setAttribute('aria-invalid', 'true');
        input.focus();
        return;
      }
      replaceChildren(message);
      try {
        const { login } = await withBusy(save, 'Checking…', () => api.post('/settings/github-token', { token }));
        input.value = '';
        onSaved(login);
      } catch (error) {
        input.setAttribute('aria-invalid', 'true');
        replaceChildren(message, problem(error.message));
      }
    },
  });
  const element = h('div', { class: 'form' },
    field({
      label: 'Personal access token',
      hint: h('span', null, externalLink(GITHUB_TOKEN_URL, 'Create a fine-grained token on GitHub'),
        ': give it your app repositories (and private Swift packages) with Contents: Read-only.'),
      control: input,
    }),
    message,
    h('div', { class: 'card-actions' },
      onCancel ? button('Cancel', { kind: 'plain', class: 'button button-plain', onClick: onCancel }) : null,
      save));
  return { element, focus: () => input.focus() };
}

function githubStep(getStatus, onChange, signal) {
  const step = stepCard(2, 'GitHub');
  let replacing = false;
  let pasting = false;
  let ghLogin; // undefined: not asked yet; null: no gh login

  async function detect() {
    try {
      ghLogin = (await api.get('/setup/github', { signal })).ghLogin ?? null;
    } catch (error) {
      if (error.code === 'aborted') return;
      ghLogin = null;
    }
    update();
  }

  function saved(login) {
    replacing = false;
    pasting = false;
    toast(`Connected to GitHub as ${login}`, 'success');
    onChange();
  }

  function update() {
    const github = getStatus().github;
    step.setDone(Boolean(github));
    if (github && !replacing) {
      replaceChildren(step.body,
        doneLine(github.login ? `Connected as ${github.login}` : 'Token saved (GitHub could not be reached to check it)'),
        h('p', { class: 'card-note' }, github.source === 'gh' ? GH_NOTE : 'Using the token you pasted.'),
        h('div', { class: 'card-actions' }, button('Use a Different Account', {
          kind: 'plain', class: 'button button-plain button-small',
          onClick: () => {
            replacing = true;
            update();
          },
        })));
      return;
    }
    // The GitHub CLI login is offered only to a browser on the server's Mac.
    if (!getStatus().viewerIsLocal) ghLogin = null;
    if (ghLogin === undefined) {
      replaceChildren(step.body, h('p', { class: 'setup-looking' }, spinner('Looking'), 'Looking for the GitHub CLI…'));
      detect();
      return;
    }
    const cancel = replacing ? button('Cancel', {
      kind: 'plain', class: 'button button-plain button-small',
      onClick: () => {
        replacing = false;
        pasting = false;
        update();
      },
    }) : null;
    const intro = h('p', { class: 'card-detail' },
      'Hangar reads your app repositories (and private Swift packages) from GitHub.');
    if (ghLogin && !pasting) {
      const message = h('div');
      const use = button(`Use ${ghLogin}’s GitHub CLI Login`, {
        kind: 'primary',
        onClick: async () => {
          replaceChildren(message);
          try {
            const { login } = await withBusy(use, 'Connecting…', () => api.post('/setup/github/use-gh'));
            saved(login);
          } catch (error) {
            replaceChildren(message, problem(error.message));
          }
        },
      });
      replaceChildren(step.body, intro,
        h('p', { class: 'card-headline' }, `The GitHub CLI on this Mac is signed in as ${ghLogin}.`),
        h('p', { class: 'card-note' }, GH_NOTE),
        message,
        h('div', { class: 'card-actions' },
          use,
          button('Paste a Token Instead', {
            kind: 'plain', class: 'button button-plain',
            onClick: () => {
              pasting = true;
              update();
            },
          }),
          cancel));
      return;
    }
    const form = tokenForm(saved, { onCancel: replacing || pasting ? () => {
      if (pasting && ghLogin) pasting = false;
      else replacing = false;
      update();
    } : undefined });
    replaceChildren(step.body, intro, form.element);
  }

  return { element: step.element, update };
}

// MARK: 3. Build Macs and signing

function machinesStep(getStatus, onChange, context) {
  const step = stepCard(3, 'Build Macs & Signing');
  const list = h('div', { class: 'grid machine-grid' });
  const local = h('div', { class: 'setup-local' });
  const signing = h('div', { class: 'setup-signing' });
  const widgets = new Map(); // machine id → widget
  const machineListeners = new Set();
  let machines = [];
  let install = null; // LocalWorkerInstall while one runs or after it ended
  let pollTimer = null;

  async function loadMachines() {
    try {
      machines = await api.get('/machines', { signal: context.signal });
    } catch {
      return;
    }
    renderMachines();
  }

  function renderMachines() {
    machines.sort((a, b) => a.name.localeCompare(b.name));
    const ids = new Set(machines.map((machine) => machine.id));
    for (const id of widgets.keys()) if (!ids.has(id)) widgets.delete(id);
    replaceChildren(list, machines.map((machine) => {
      let widget = widgets.get(machine.id);
      if (!widget) {
        widget = machineWidget(machine, {
          onRemove: async (target) => {
            if (await removeMachine(target)) {
              machines = machines.filter((existing) => existing.id !== target.id);
              renderMachines();
              onChange();
            }
          },
        });
        widgets.set(machine.id, widget);
      } else {
        widget.update(machine);
      }
      return widget.element;
    }));
    list.hidden = machines.length === 0;
    renderSigning();
  }

  function renderLocal() {
    const status = getStatus();
    if (status.localWorker && !install) {
      replaceChildren(local);
      return;
    }
    if (install) {
      const log = h('pre', { class: 'code-block install-log', tabindex: '0', 'aria-label': 'Install output' },
        h('code', null, install.lines.join('\n') || 'Starting…'));
      const head = install.state === 'running'
        ? h('p', { class: 'setup-looking', role: 'status' }, spinner('Installing'), `Installing the worker on ${status.localHostName ?? 'this Mac'}…`)
        : install.state === 'succeeded'
          ? doneLine(`${install.machine?.name ?? 'This Mac'} is installed. It shows up below once the worker starts.`)
          : problem(install.message ?? 'The install failed.');
      replaceChildren(local, head, log,
        install.state === 'failed' ? h('div', { class: 'card-actions' }, useThisMacButton('Try Again')) : null);
      queueMicrotask(() => { log.scrollTop = log.scrollHeight; });
      return;
    }
    if (!status.viewerIsLocal) {
      replaceChildren(local, h('p', { class: 'card-detail' },
        `To build on ${status.localHostName ?? 'the Mac Hangar runs on'} with one click, open Hangar on that Mac. `
        + 'Or add any Mac with one command in its Terminal.'));
      return;
    }
    if (status.installedWorker) {
      const worker = status.installedWorker;
      replaceChildren(local, h('p', { class: 'card-detail' },
        `A worker is already set up on ${status.localHostName ?? 'this Mac'}`
        + (worker.serverURL ? ` for ${worker.serverURL}` : '')
        + '. Hangar leaves it alone; to update it, run the install command again in Terminal.'),
      worker.serverURL ? h('pre', { class: 'code-block install-log', tabindex: '0', 'aria-label': 'Update command' },
        h('code', null, `curl -fsSL ${worker.serverURL}/install | sh`)) : null);
      return;
    }
    if (!status.localHostName) {
      replaceChildren(local);
      return;
    }
    if (!status.workerInstallAvailable) {
      replaceChildren(local, h('p', { class: 'card-note' },
        'This server has no hangar-worker to install, so it cannot build on this Mac by itself. Reinstall the '
        + 'server with the latest install-server.sh, or add a Mac below.'));
      return;
    }
    replaceChildren(local,
      h('p', { class: 'card-detail' },
        `Build on ${status.localHostName}, the Mac Hangar runs on: Hangar installs its worker for your user `
        + '(into ~/.local/bin, started at login) and enrolls it.'),
      h('div', { class: 'card-actions' }, useThisMacButton('Use This Mac for Builds')));
  }

  function useThisMacButton(label) {
    const control = button(label, {
      kind: 'primary',
      onClick: async () => {
        try {
          install = await withBusy(control, 'Starting…', () => api.post('/setup/local-worker'));
        } catch (error) {
          install = { state: 'failed', lines: [], message: error.message };
        }
        renderLocal();
        if (install.state === 'running') poll();
      },
    });
    return control;
  }

  function poll() {
    clearTimeout(pollTimer);
    pollTimer = setTimeout(async () => {
      try {
        install = await api.get('/setup/local-worker', { signal: context.signal });
      } catch (error) {
        if (error.code === 'aborted') return;
        install = { state: 'failed', lines: install?.lines ?? [], message: error.message };
      }
      renderLocal();
      if (install.state === 'running') {
        poll();
      } else if (install.state === 'succeeded') {
        toast(`${install.machine?.name ?? 'This Mac'} is set up for builds`, 'success');
        onChange();
        loadMachines();
      }
    }, INSTALL_POLL_MS);
  }

  function renderSigning() {
    const status = getStatus();
    const reported = machines.filter((machine) => machine.report);
    const individual = status.appStoreConnect?.kind === 'individual';
    const noAccount = reported.filter((machine) => machine.report.xcodeAccountSignedIn === false);
    replaceChildren(signing,
      h('h3', { class: 'machine-group-title' }, 'Signing'),
      h('p', { class: 'card-note' },
        'Distribution certificates are created and managed by Xcode automatically (cloud-managed signing). With an '
        + 'individual API key, Xcode uses the Apple account signed in to Xcode on each Mac; with a team key it uses '
        + 'the key.'),
      individual && noAccount.length
        ? h('div', { class: 'signing signing-warning', role: 'note' },
          h('span', { class: 'signing-icon', 'aria-hidden': 'true' }, '!'),
          h('div', null,
            h('p', { class: 'signing-title' },
              `${noAccount.map((machine) => machine.name).join(', ')} ${noAccount.length === 1 ? 'has' : 'have'} no Apple account in Xcode`),
            h('p', { class: 'card-note' },
              'With an individual key, archives cannot be signed for distribution there. On that Mac, open Xcode › '
              + 'Settings › Accounts and sign in with your Apple Account.')))
        : null);
    signing.hidden = machines.length === 0;
  }

  function update() {
    const status = getStatus();
    step.setDone(status.machines > 0);
    // Without a one-click install here, adding a Mac by command is the way: make it the step's button.
    const primary = status.machines === 0 && (!status.viewerIsLocal || status.installedWorker || !status.workerInstallAvailable);
    addButton.textContent = status.machines === 0 ? 'Add a Mac…' : 'Add Another Mac…';
    addButton.className = primary ? 'button button-primary' : 'button button-plain button-small';
    renderLocal();
    renderSigning();
  }

  function addMac() {
    openAddMacSheet({
      knownIDs: new Set(machines.map((machine) => machine.id)),
      listen: (listener) => {
        machineListeners.add(listener);
        return () => machineListeners.delete(listener);
      },
      onManual: () => openAddMachineSheet({ onAdded: () => { loadMachines(); onChange(); } }),
    });
  }

  const addButton = button('Add Another Mac…', { kind: 'plain', class: 'button button-plain button-small', onClick: addMac });
  replaceChildren(step.body, local, list, signing, h('div', { class: 'card-actions' }, addButton));
  list.hidden = true;
  loadMachines();

  context.onCleanup(() => clearTimeout(pollTimer));
  context.onCleanup(events((event) => {
    if (event.type !== 'machine' || !event.machine) return;
    machineListeners.forEach((listener) => listener(event.machine));
    const index = machines.findIndex((machine) => machine.id === event.machine.id);
    if (index >= 0) {
      machines[index] = event.machine;
      renderMachines();
    } else {
      loadMachines();
      onChange();
    }
  }, { onReconnect: () => { loadMachines(); onChange(); } }));

  return { element: step.element, update };
}

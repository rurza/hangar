// The Machines page: a widget per build Mac with its latest heartbeat report, the Add Mac sheet (the one-line
// install command and a pairing code; it waits for the new Mac to connect), Pause/Resume Builds and Remove.

import { api, events, seg } from '../api.js';
import {
  button, card, checkBadge, confirm, copyText, emptyState, field, h, page, relativeTime, replaceChildren, ring,
  plusIcon, selectContents, sheet, spinner, toast,
} from '../ui.js';
import {
  buildUserWarning, isOnline, isServerMac, loadText, pauseButtonLabel, pauseToast, vmChecklist, vmLine, vmSigningLine, xcodeDrift,
} from '../machine-status.js';
import { platformName } from '../workflow-summary.js';

/** How often the online dots and "last seen" times are re-evaluated without a heartbeat event. */
const TICK_MS = 15_000;

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]', '::1']);

/** The `/machines` route. */
export async function machinesPage(params, context) {
  const content = h('div');
  const widgets = new Map(); // machine id → widget
  let machines = await api.get('/machines', { signal: context.signal });
  // Called with every machine event, for the Add Mac sheet that waits for its Mac.
  const machineListeners = new Set();
  // The page's own Add button; the empty state has its own.
  const addButton = button('Add Mac', { kind: 'primary', onClick: () => addMac() });
  // What each running job is ("Legilo 88 · macOS"), for the widgets; refreshed when a machine reports jobs.
  const jobs = runningJobs(context.signal, () => widgets.forEach((widget) => widget.refresh()));
  // The Mac the server runs on, to mark its card; known once /setup answers.
  let serverHostName = null;
  const serverMac = (machine) => isServerMac(machine, serverHostName);
  // The server's signing certificate, for VM Macs' cards; null until /signing answers.
  let signing = null;
  const signingStatus = () => signing;

  function render() {
    machines.sort((a, b) => a.name.localeCompare(b.name));
    addButton.hidden = machines.length === 0;
    if (machines.length === 0) {
      widgets.clear();
      replaceChildren(content, emptyState({
        icon: h('span', { class: 'empty-plus' }, plusIcon()),
        title: 'No Machines Yet',
        message: 'Add a Mac that runs your builds: run one command in its Terminal and type a short code.',
        action: button('Add Mac', { kind: 'primary', onClick: addMac }),
      }));
      return;
    }
    // Widgets are kept across renders, so a focused Remove button stays focused when a heartbeat arrives.
    const ids = new Set(machines.map((machine) => machine.id));
    for (const id of widgets.keys()) if (!ids.has(id)) widgets.delete(id);
    const nodes = machines.map((machine) => {
      let widget = widgets.get(machine.id);
      if (!widget) {
        widget = machineWidget(machine, {
          onRemove: remove, onPause: setPaused, onVMBuilds: setVMBuilds, jobInfo: jobs.info, serverMac, signingStatus,
        });
        widgets.set(machine.id, widget);
      } else {
        widget.update(machine);
      }
      return widget.element;
    });
    replaceChildren(content, h('div', { class: 'grid machine-grid' }, nodes));
    jobs.want(machines.flatMap((machine) => machine.report?.runningJobIDs ?? []));
  }

  function upsert(machine) {
    const index = machines.findIndex((existing) => existing.id === machine.id);
    if (index >= 0) machines[index] = machine;
    else machines.push(machine);
    render();
  }

  async function reload() {
    try {
      machines = await api.get('/machines', { signal: context.signal });
      render();
    } catch {
      // The next heartbeat or reconnect tries again.
    }
  }

  function addMac() {
    openAddMacSheet({
      knownIDs: new Set(machines.map((machine) => machine.id)),
      listen: (listener) => {
        machineListeners.add(listener);
        return () => machineListeners.delete(listener);
      },
    });
  }

  async function remove(machine) {
    const removed = await removeMachine(machine);
    if (removed) {
      machines = machines.filter((existing) => existing.id !== machine.id);
      render();
    } else if (removed === false) {
      reload();
    }
  }

  /** Turns builds on `machine` off or on again; no confirmation, since it is undone with one click. */
  async function setPaused(machine, paused) {
    try {
      const updated = await api.post(`/machines/${seg(machine.id)}/${paused ? 'pause' : 'resume'}`);
      toast(pauseToast(updated), 'success');
      upsert(updated);
    } catch (error) {
      toast(error.message, 'error');
    }
  }

  /** Allows or stops VM builds on `machine`: the owner's decision, which a heartbeat cannot make. */
  async function setVMBuilds(machine, allowed) {
    try {
      const updated = allowed
        ? await api.post(`/machines/${seg(machine.id)}/vm-builds`)
        : await api.del(`/machines/${seg(machine.id)}/vm-builds`);
      toast(allowed ? `VM builds allowed on ${updated.name}` : `VM builds stopped on ${updated.name}`, 'success');
      upsert(updated);
    } catch (error) {
      toast(error.message, 'error');
    }
  }

  render();
  api.get('/setup', { signal: context.signal }).then((setup) => {
    serverHostName = setup?.localHostName ?? null;
    if (serverHostName) widgets.forEach((widget) => widget.refresh());
  }, () => {});
  if (machines.some((machine) => machine.report?.vm)) loadSigning();

  /** Fetches the signing status once a VM Mac is shown. */
  function loadSigning() {
    if (signing) return;
    api.get('/signing', { signal: context.signal }).then((status) => {
      signing = status;
      widgets.forEach((widget) => widget.refresh());
    }, () => {});
  }
  if (context.query.get('add') === '1') {
    history.replaceState(null, '', '/machines');
    addMac();
  }

  const timer = setInterval(() => widgets.forEach((widget) => widget.tick()), TICK_MS);
  context.onCleanup(() => clearInterval(timer));
  context.onCleanup(events((event) => {
    if (event.type !== 'machine' || !event.machine) return;
    machineListeners.forEach((listener) => listener(event.machine));
    // A known machine is updated in place. An unknown one was just enrolled (or was removed meanwhile, and must
    // not come back), so the list is fetched again instead.
    if (machines.some((m) => m.id === event.machine.id)) upsert(event.machine);
    else reload();
    if (event.machine.report?.vm) loadSigning();
  }, { onReconnect: reload }));

  return page({
    title: 'Machines',
    actions: addButton,
  }, content);
}

/**
 * Asks to remove `machine` and removes it. Resolves to true once it is gone, null when the user said no, false
 * when it failed (the error is shown).
 */
export async function removeMachine(machine) {
  const confirmed = await confirm({
    title: `Remove ${machine.name}?`,
    message: 'Its token stops working at once, so the worker on that Mac can no longer take jobs. '
      + 'To use the Mac again, add it as a new machine and install the worker with the new token.',
    confirmLabel: 'Remove',
    destructive: true,
  });
  if (!confirmed) return null;
  try {
    await api.del(`/machines/${seg(machine.id)}`);
    toast(`Removed ${machine.name}`, 'success');
    return true;
  } catch (error) {
    toast(error.message, 'error');
    return false;
  }
}

// MARK: Widget

/**
 * A machine's widget. `update(machine)` redraws it with new data, `tick()` re-evaluates the online state.
 * `onPause(machine, paused)` adds the Pause/Resume Builds button; `serverMac(machine)` marks the server's own Mac.
 */
export function machineWidget(initial, { onRemove, onPause, onVMBuilds, jobInfo, serverMac, signingStatus }) {
  let machine = initial;
  const title = h('h2', { class: 'machine-name' });
  const status = h('p', { class: 'machine-status' });
  const tags = h('div', { class: 'machine-tags' });
  const body = h('div', { class: 'machine-body' });
  const removeButton = button('Remove', {
    kind: 'plain-destructive', class: 'button button-plain-destructive button-small',
    onClick: () => onRemove(machine),
  });
  let pausing = false;
  const pauseButton = onPause ? button('', {
    class: 'button button-secondary button-small machine-pause',
    onClick: async () => {
      if (pausing) return;
      pausing = true;
      pauseButton.disabled = true;
      try {
        await onPause(machine, !machine.paused);
      } finally {
        pausing = false;
        pauseButton.disabled = false;
      }
    },
  }) : null;
  // Shown once the Mac reports VM builds, or while the owner allows them.
  const vmButton = onVMBuilds ? button('', {
    class: 'button button-secondary button-small machine-vm-builds',
    onClick: async () => {
      vmButton.disabled = true;
      try {
        await onVMBuilds(machine, !machine.vmBuilds);
      } finally {
        vmButton.disabled = false;
      }
    },
  }) : null;
  const element = card({ class: 'machine-card' },
    h('div', { class: 'machine-head' }, h('div', { class: 'machine-heading' }, title, status), tags),
    body,
    h('div', { class: 'card-actions' }, vmButton, pauseButton, removeButton));

  function tick() {
    const online = isOnline(machine);
    const seen = machine.lastSeenAt
      ? `${online ? 'Online' : 'Offline'} · seen ${relativeTime(machine.lastSeenAt)}`
      : 'Never connected';
    replaceChildren(status,
      h('span', { class: ['online-dot', online ? 'online' : 'offline'], 'aria-hidden': 'true' }),
      h('span', null, seen));
  }

  function update(next) {
    machine = next;
    title.textContent = machine.name;
    removeButton.setAttribute('aria-label', `Remove ${machine.name}`);
    element.classList.toggle('machine-paused', Boolean(machine.paused));
    if (pauseButton) {
      pauseButton.textContent = pauseButtonLabel(machine.paused);
      pauseButton.setAttribute('aria-label', `${pauseButtonLabel(machine.paused)} on ${machine.name}`);
    }
    replaceChildren(tags,
      serverMac?.(machine)
        ? h('span', { class: 'tag', title: 'Hangar’s server runs on this Mac' }, 'Server')
        : null,
      machine.paused ? h('span', { class: 'badge badge-paused' }, h('span', { class: 'badge-dot', 'aria-hidden': 'true' }), 'Paused') : null);
    if (vmButton) {
      vmButton.hidden = !machine.vmBuilds && !machine.report?.vm;
      vmButton.textContent = machine.vmBuilds ? 'Stop VM Builds' : 'Allow VM Builds';
      vmButton.setAttribute('aria-label', `${vmButton.textContent} on ${machine.name}`);
    }
    replaceChildren(body, machine.report ? reportView(machine, jobInfo, signingStatus?.()) : waitingView());
    tick();
  }

  update(initial);
  return { element, update, tick, refresh: () => update(machine) };
}

function waitingView() {
  return h('p', { class: 'card-detail' },
    'Waiting for the first heartbeat. The worker sends one as soon as it is installed and running on this Mac.');
}

function reportView(machine, jobInfo, signing) {
  const report = machine.report;
  // A VM Mac runs a job per VM slot, whatever its own job limit says.
  const max = Math.max(1, report.vm ? report.vm.configuredSlots ?? report.vm.slots ?? 1 : machine.maxConcurrentJobs ?? 1);
  const runningIDs = Array.isArray(report.runningJobIDs) ? report.runningJobIDs : [];
  const running = runningIDs.length;
  const jobs = max === 1 ? 'job' : 'jobs';
  const load = loadText({
    running, max, paused: Boolean(machine.paused), vmNotReady: Boolean(report.vm) && !((report.vm.slots ?? 0) > 0),
  });
  // "Building Legilo 88 · macOS" as links to the builds, once known.
  const known = runningIDs.map((id) => jobInfo?.(id)).filter(Boolean);
  const verb = known.length && known.every((info) => info.kind === 'test') ? 'Testing' : 'Building';
  const activity = load.headline
    ? h('p', { class: 'card-headline' }, load.headline)
    : known.length
      ? h('p', { class: 'card-headline machine-activity' }, `${verb} `, known.map((info, index) => [
        index ? ', ' : null,
        h('a', { href: `/builds/${seg(info.buildID)}`, 'data-link': true }, info.label)]))
      : h('p', { class: 'card-headline' }, 'Building');
  const fact = (label, value) => h('div', { class: 'fact' },
    h('dt', { class: 'fact-label' }, label),
    h('dd', { class: 'fact-value' }, value));
  const xcodes = [...(report.xcodes ?? [])].sort((a, b) => b.version.localeCompare(a.version, 'en', { numeric: true }));
  const tools = Object.entries(report.tools ?? {}).sort(([a], [b]) => a.localeCompare(b));
  const identities = Array.isArray(report.signingIdentities) ? report.signingIdentities : [];

  return [
    h('div', { class: 'machine-load' },
      ring(running / max, `${running} of ${max} ${jobs} running`),
      h('div', { class: 'machine-load-text' },
        activity,
        h('p', { class: 'card-detail' }, load.detail))),
    report.vm ? vmView(report.vm, machine.vmBuilds) : null,
    driftView(xcodeDrift(report)),
    // Once VM builds are ready; until then the checklist is the one thing to act on.
    (report.vm?.slots ?? 0) > 0 ? vmSigningView(vmSigningLine(report.vm, signing)) : null,
    h('dl', { class: 'facts' },
      fact('Chip', report.chip || '–'),
      fact('Performance cores', String(report.performanceCores)),
      fact('Memory', `${report.memoryGB} GB`),
      fact('Free disk', `${formatGB(report.freeDiskGB)} GB`),
      fact('Power', report.onACPower ? 'Power adapter' : 'Battery'),
      fact('macOS', report.macOSVersion || '–'),
      // A VM Mac signs in its VMs; its own Xcode account plays no part.
      report.vm ? null : fact('Xcode account', xcodeAccountText(report.xcodeAccountSignedIn, report.headless)),
      report.vm
        ? fact('Builds run as', 'builder, in a fresh VM')
        : fact('Runs as', report.runningUser || '–')),
    buildUserWarningView(buildUserWarning(report)),
    // On a VM Mac the host's Xcode only feeds new images; jobs get the images' (the VM line).
    chipGroup(report.vm ? 'Xcode on This Mac (for New Images)' : 'Xcode',
      xcodes.map((xcode) => `${xcode.version} (${xcode.build})`), 'No Xcode found'),
    // The name only; where it lives is a tooltip. A VM job installs its own tools.
    report.vm ? null : chipGroup('Tools', tools.map(([name, detail]) => ({ text: name, title: detail || null })), 'None reported'),
    // A VM Mac signs in its VMs with Hangar's certificate (Settings › Signing), not with its own keychain.
    report.vm ? null : chipGroup('Signing identities', identities, 'None in the keychain yet'),
    report.vm ? null : report.canSignWithoutPrompt
      ? h('p', { class: 'signing signing-ok' },
        checkBadge('signing-icon'),
        report.headless ? 'Can sign with its CI keychain' : 'Can sign without a prompt')
      : h('div', { class: 'signing signing-warning' },
        h('span', { class: 'signing-icon', 'aria-hidden': 'true' }, '!'),
        h('div', null,
          h('p', { class: 'signing-title' }, 'Cannot sign without a prompt'),
          h('p', { class: 'card-note' }, cannotSignAdvice(report)))),
    !report.vm && report.headless
      ? h('p', { class: 'card-note' },
        'Runs without a login, so it has no Xcode account: archives here need a team App Store Connect key '
        + '(with an issuer ID).')
      : null,
  ];
}

/** What to do about a machine that cannot sign: headless, the keychain's own problem; otherwise Keychain Access. */
function cannotSignAdvice(report) {
  if (report.headless) {
    return `Signing jobs skip this Mac until it can sign: ${report.keychainProblem || 'its CI keychain is not ready'}. `
      + 'In Terminal on this Mac, as an administrator, run hangar-worker isolate again.';
  }
  return 'Signing jobs skip this Mac until it can sign. As the hangar user, open Keychain Access, find the '
    + 'Apple Development private key and allow codesign under Access Control; then run hangar-worker doctor.';
}

/**
 * A VM Mac's slots, images and network filter on one line; while no slot is ready, the whole checklist with the
 * command to run on the Mac. Once ready, only an optional row that is not done (slot states) is mentioned. Until the
 * owner allows VM builds on it (`allowed`), it says so first: a heartbeat alone gets no VM jobs.
 */
function vmView(vm, allowed) {
  const line = vmLine(vm);
  const checklist = vmChecklist(vm);
  const notAllowed = allowed ? null : h('div', { class: 'signing signing-warning' },
    h('span', { class: 'signing-icon', 'aria-hidden': 'true' }, '!'),
    h('div', null,
      h('p', { class: 'signing-title' }, 'VM builds not allowed yet'),
      h('p', { class: 'card-note' }, 'This Mac is set up for VM builds. Allow them to give it jobs and the signing '
        + 'certificate; only allow a Mac you set up yourself.')));
  if (checklist.ready) {
    const pending = checklist.rows.filter((row) => !row.ok);
    return [
      h('p', { class: 'card-detail machine-vm' }, line.text),
      notAllowed,
      pending.map((row) => h('p', { class: 'card-note' }, `${row.title}: ${row.detail}`)),
    ];
  }
  return [
    h('p', { class: 'card-detail machine-vm' }, line.text),
    notAllowed,
    h('div', { class: 'signing signing-warning vm-setup' },
      h('span', { class: 'signing-icon', 'aria-hidden': 'true' }, '!'),
      h('div', null,
        h('p', { class: 'signing-title' }, 'VM builds not ready'),
        checklist.command
          ? [h('p', { class: 'card-note' }, 'In Terminal on this Mac, as an administrator, run:'), commandBlock(checklist.command)]
          : null,
        h('ul', { class: 'vm-checklist', 'aria-label': 'VM builds checklist' }, checklist.rows.map(checkRow)))),
  ];
}

/** `vmSigningLine` as the card's signing row: a check, or a warning that links to Settings › Signing. */
function vmSigningView(line) {
  if (!line) return null;
  const link = line.link ? [' ', h('a', { href: '/settings', 'data-link': true }, 'Settings › Signing'), '.'] : null;
  if (line.ok) return h('p', { class: 'signing signing-ok' }, checkBadge('signing-icon'), line.text);
  return h('div', { class: 'signing signing-warning' },
    h('span', { class: 'signing-icon', 'aria-hidden': 'true' }, '!'),
    h('div', null, h('p', { class: 'card-note' }, line.text, link)));
}

/** `xcodeDrift`'s note, or nothing. */
function driftView(drift) {
  if (!drift) return null;
  return h('div', { class: 'signing signing-warning' },
    h('span', { class: 'signing-icon', 'aria-hidden': 'true' }, '!'),
    h('div', null,
      h('p', { class: 'signing-title' }, drift.title),
      h('p', { class: 'card-note' }, drift.note),
      drift.command ? commandBlock(drift.command) : null));
}

function checkRow(row) {
  const state = row.ok ? 'done' : row.required ? 'missing' : 'optional';
  return h('li', { class: ['vm-check', `vm-check-${state}`] },
    h('span', { class: 'vm-check-icon', 'aria-hidden': 'true' }, row.ok ? '✓' : row.required ? '✕' : '–'),
    h('div', { class: 'vm-check-text' },
      h('span', { class: 'vm-check-title' }, row.title),
      h('span', { class: 'visually-hidden' }, row.ok ? ', done: ' : row.required ? ', missing: ' : ', optional: '),
      h('span', { class: 'vm-check-detail' }, row.detail),
      row.command ? commandBlock(row.command) : null));
}

/** A command to paste in Terminal, with its Copy button. */
function commandBlock(command) {
  const code = h('code', { class: 'vm-command-text' }, command);
  return h('div', { class: 'vm-command' },
    code,
    button('Copy', {
      kind: 'plain', class: 'button button-plain button-small', 'aria-label': 'Copy the command',
      onClick: async () => {
        if (await copyText(command)) {
          toast('Copied the command', 'success');
        } else {
          selectContents(code);
          toast('The command is selected. Press ⌘C to copy it.', 'info');
        }
      },
    }));
}

/** `buildUserWarning`'s warning as the card's warning box, or nothing. */
function buildUserWarningView(warning) {
  if (!warning) return null;
  return h('div', { class: 'signing signing-warning' },
    h('span', { class: 'signing-icon', 'aria-hidden': 'true' }, '!'),
    h('div', null,
      h('p', { class: 'signing-title' }, warning.title),
      h('p', { class: 'card-note' }, warning.note)));
}

/** "Signed in", "Not signed in", "None (no login)" for a headless worker, or "–" (an older worker does not say). */
export function xcodeAccountText(signedIn, headless = false) {
  if (headless) return 'None (no login)';
  if (signedIn === true) return 'Signed in';
  if (signedIn === false) return 'Not signed in';
  return '–';
}

function chipGroup(label, items, emptyText) {
  return h('div', { class: 'machine-group' },
    h('h3', { class: 'machine-group-title' }, label),
    items.length
      ? h('ul', { class: 'chips', 'aria-label': label }, items.map((item) => (typeof item === 'string'
        ? h('li', { class: 'chip' }, item)
        : h('li', { class: 'chip', title: item.title }, item.text))))
      : h('p', { class: 'card-note' }, emptyText));
}

/**
 * What the running jobs are, looked up from the latest builds. `want(ids)` fetches when an id is not known yet
 * (once at a time) and calls `onChange()`; `info(id)` is `{ buildID, label }` or undefined.
 */
function runningJobs(signal, onChange) {
  const known = new Map(); // job id → { buildID, kind, label }
  const tried = new Set(); // ids looked for once already, found or not
  let loading = null;
  let apps = null;

  async function load(ids) {
    try {
      const [builds, list] = await Promise.all([
        api.get('/builds?limit=50', { signal }),
        apps ? Promise.resolve(apps) : api.get('/apps', { signal }),
      ]);
      apps = list;
      const names = new Map(apps.map((app) => [app.id, app.name]));
      for (const build of builds) {
        for (const job of build.jobs ?? []) {
          known.set(job.id, {
            buildID: build.id,
            kind: job.action?.kind,
            label: `${names.get(build.appID) ?? 'a build'} ${build.buildNumber} · ${platformName(job.action?.platform)}`,
          });
        }
      }
      // Marked as looked for only once answered: after a failed request they are asked for again.
      ids.forEach((id) => tried.add(id));
      onChange();
    } catch {
      // Without it the widget says "Building" without naming it.
    }
  }

  return {
    info: (id) => known.get(id),
    want(ids) {
      const missing = ids.filter((id) => !known.has(id) && !tried.has(id));
      if (loading || missing.length === 0) return;
      loading = load(missing).finally(() => { loading = null; });
    },
  };
}

function formatGB(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '–';
  return value >= 100 ? String(Math.round(value)) : value.toFixed(1);
}

// MARK: Add Mac

/** "14:32" for a number of seconds. */
function minutesAndSeconds(seconds) {
  const whole = Math.max(0, Math.ceil(seconds));
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`;
}

/**
 * The one-command install: the `curl … | sh` line and a pairing code with its countdown. Waits for a machine that
 * was not in `knownIDs` to enroll and then to send its first heartbeat. `listen(fn)` delivers machine events and
 * returns the function that stops them.
 */
export function openAddMacSheet({ knownIDs, listen }) {
  const isLocal = LOCAL_HOSTS.has(location.hostname);
  // Other Macs cannot reach localhost: the command then names the server by an address they can, which the
  // user can correct (filled in with this Mac's network name once the server says it).
  const hostInput = isLocal ? h('input', {
    class: 'input mono', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
    value: location.origin, 'aria-describedby': 'add-mac-host-hint',
    onInput: () => renderCommand(),
  }) : null;
  const commandCode = h('code');
  const commandBlock = h('pre', { class: 'code-block', tabindex: '0', 'aria-label': 'Install command' }, commandCode);
  let command = '';
  function renderCommand() {
    const origin = (hostInput?.value.trim() || location.origin).replace(/\/+$/, '');
    command = `curl -fsSL ${origin}/install | sh`;
    commandCode.textContent = command;
  }
  renderCommand();
  const codeText = h('span', { class: 'pairing-code', 'aria-label': 'Pairing code' }, '····-····');
  const expiry = h('span', { class: 'pairing-expiry' }, 'Getting a code…');
  const newCodeButton = button('Get a New Code', {
    kind: 'plain', class: 'button button-plain button-small', hidden: true, onClick: () => newCode(),
  });
  const copyCodeButton = button('Copy Code', {
    kind: 'plain', class: 'button button-plain button-small', disabled: true,
    onClick: () => copy(pairing?.code ?? '', codeText, 'code'),
  });
  const notices = h('div', { class: 'pairing-notices' });
  const status = h('div', { class: 'pairing-status', role: 'status', 'aria-live': 'polite' });

  let pairing = null;
  let deadline = 0; // performance.now() when the code expires, from the server's expiresIn
  let enrolled = null; // the new machine, once it has enrolled
  let timer = null;

  async function copy(text, block, what) {
    if (text && await copyText(text)) {
      toast(`Copied the ${what}`, 'success');
      return;
    }
    selectContents(block);
    toast(`The ${what} is selected. Press ⌘C to copy it.`, 'info');
  }

  function tick() {
    if (enrolled) {
      expiry.textContent = 'Code used.';
      newCodeButton.hidden = true;
      return;
    }
    if (!pairing) return;
    // Counted from the server's remaining time on a monotonic clock, so a wrong browser clock does not matter.
    const seconds = (deadline - performance.now()) / 1000;
    const expired = seconds <= 0;
    expiry.textContent = expired ? 'This code has expired.' : `Expires in ${minutesAndSeconds(seconds)}`;
    codeText.classList.toggle('pairing-code-expired', expired);
    copyCodeButton.disabled = expired;
    newCodeButton.hidden = !expired;
  }

  async function newCode() {
    newCodeButton.disabled = true;
    handle?.setError(null);
    try {
      pairing = await api.post('/machines/pairings');
      deadline = performance.now() + Number(pairing.expiresIn) * 1000;
      codeText.textContent = pairing.code;
      copyCodeButton.disabled = false;
      tick();
    } catch (error) {
      expiry.textContent = 'No code.';
      newCodeButton.hidden = false;
      handle?.setError(error.message);
    } finally {
      newCodeButton.disabled = false;
    }
  }

  function showStatus() {
    if (!enrolled) {
      replaceChildren(status, spinner('Waiting'), h('span', null, 'Waiting for the Mac…'));
    } else if (!enrolled.lastSeenAt) {
      replaceChildren(status, spinner('Starting'),
        h('span', null, `${enrolled.name} is enrolled. Waiting for the worker to start…`));
    } else {
      replaceChildren(status,
        checkBadge('pairing-connected-icon'),
        h('span', { class: 'pairing-connected' }, enrolled.paused
          ? `${enrolled.name} is connected. Its builds are paused until VM builds are ready; its card shows the progress.`
          : `${enrolled.name} is connected`));
      handle.setActions([{ label: 'Done', kind: 'primary' }]);
      handle.element.querySelector('.sheet-actions .button-primary')?.focus();
    }
  }

  const stopListening = listen((machine) => {
    if (knownIDs.has(machine.id) || (enrolled && enrolled.id !== machine.id)) return;
    enrolled = machine;
    tick();
    showStatus();
  });

  if (isLocal) {
    api.get('/setup').then((setup) => {
      // The tailnet name reaches the server from any Mac on the tailnet; the Bonjour name only on this LAN.
      const host = setup?.tailnetName || (setup?.localHostName ? `${setup.localHostName}.local` : null);
      if (!host || hostInput.value !== location.origin) return;
      hostInput.value = `${location.protocol}//${host}${location.port ? `:${location.port}` : ''}`;
      renderCommand();
    }, () => {});
  }
  api.get('/settings').then((settings) => {
    if (settings && settings.workerInstallAvailable === false) {
      notices.append(h('p', { class: 'token-warning', role: 'note' },
        'This server has no hangar-worker to hand out, so the command cannot install it. Reinstall the server '
        + 'with the latest install-server.sh to enable it.'));
    }
  }, () => {});

  const handle = sheet({
    title: 'Add Mac',
    onClose: () => {
      clearInterval(timer);
      stopListening();
    },
    body: h('div', { class: 'form pairing-sheet' },
      notices,
      h('ol', { class: 'pairing-steps' },
        h('li', null, 'On the new Mac, open Terminal and run the command.'),
        h('li', null, 'Type the code when asked.')),
      hostInput ? field({
        label: 'Server address',
        hint: h('span', { id: 'add-mac-host-hint' },
          `This page is open on ${location.host}, which other Macs can’t reach. Use an address they can, `
          + 'such as the server’s tailnet name.'),
        control: hostInput,
      }) : null,
      h('div', { class: 'code-field' },
        h('div', { class: 'field-label-row' },
          h('span', { class: 'field-label' }, 'Command'),
          button('Copy Command', {
            kind: 'plain', class: 'button button-plain button-small',
            onClick: () => copy(command, commandBlock, 'command'),
          })),
        commandBlock,
        h('p', { class: 'field-hint' },
          'Run it in Terminal as an administrator. It installs the worker, then sets up VM builds, so each build '
          + 'runs in a fresh macOS VM: about 15 minutes and one password. The Mac takes no builds until then.')),
      h('div', { class: 'code-field' },
        h('div', { class: 'field-label-row' },
          h('span', { class: 'field-label' }, 'Pairing code'),
          copyCodeButton),
        h('div', { class: 'pairing-code-box' }, codeText),
        h('div', { class: 'pairing-expiry-row' }, expiry, newCodeButton)),
      status),
    actions: [{ label: 'Close', kind: 'secondary' }],
  });

  showStatus();
  timer = setInterval(tick, 1000);
  newCode();
}

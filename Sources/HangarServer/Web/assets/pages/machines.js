// The Machines page: a widget per build Mac with its latest heartbeat report, the Add Machine sheet (which shows
// the new machine's token once, with the install commands) and Remove.

import { api, events, seg } from '../api.js';
import {
  button, card, confirm, copyText, emptyState, field, h, page, relativeTime, replaceChildren, ring, selectContents,
  sheet, toast,
} from '../ui.js';
import { isOnline } from './build.js';

/** How often the online dots and "last seen" times are re-evaluated without a heartbeat event. */
const TICK_MS = 15_000;

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]', '::1']);

/** The `/machines` route. */
export async function machinesPage(params, context) {
  const content = h('div');
  const widgets = new Map(); // machine id → widget
  let machines = await api.get('/machines', { signal: context.signal });
  // The page's own Add button; the empty state has its own.
  const addButton = button('Add Machine', { kind: 'primary', onClick: () => addMachine() });

  function render() {
    machines.sort((a, b) => a.name.localeCompare(b.name));
    addButton.hidden = machines.length === 0;
    if (machines.length === 0) {
      widgets.clear();
      replaceChildren(content, emptyState({
        icon: h('span', { class: 'empty-plus' }, '+'),
        title: 'No Machines Yet',
        message: 'Add a Mac that runs your builds. You get a token and the commands to install the worker on it.',
        action: button('Add Machine', { kind: 'primary', onClick: addMachine }),
      }));
      return;
    }
    // Widgets are kept across renders, so a focused Remove button stays focused when a heartbeat arrives.
    const ids = new Set(machines.map((machine) => machine.id));
    for (const id of widgets.keys()) if (!ids.has(id)) widgets.delete(id);
    const nodes = machines.map((machine) => {
      let widget = widgets.get(machine.id);
      if (!widget) {
        widget = machineWidget(machine, { onRemove: remove });
        widgets.set(machine.id, widget);
      } else {
        widget.update(machine);
      }
      return widget.element;
    });
    replaceChildren(content, h('div', { class: 'grid machine-grid' }, nodes));
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

  function addMachine() {
    openAddMachineSheet({ onAdded: upsert });
  }

  async function remove(machine) {
    const confirmed = await confirm({
      title: `Remove ${machine.name}?`,
      message: 'Its token stops working at once, so the worker on that Mac can no longer take jobs. '
        + 'To use the Mac again, add it as a new machine and install the worker with the new token.',
      confirmLabel: 'Remove',
      destructive: true,
    });
    if (!confirmed) return;
    try {
      await api.del(`/machines/${seg(machine.id)}`);
      machines = machines.filter((existing) => existing.id !== machine.id);
      render();
      toast(`Removed ${machine.name}`, 'success');
    } catch (error) {
      toast(error.message, 'error');
      reload();
    }
  }

  render();

  const timer = setInterval(() => widgets.forEach((widget) => widget.tick()), TICK_MS);
  context.onCleanup(() => clearInterval(timer));
  context.onCleanup(events((event) => {
    // Heartbeats only update machines; one that was removed meanwhile is not brought back.
    if (event.type === 'machine' && event.machine && machines.some((m) => m.id === event.machine.id)) {
      upsert(event.machine);
    }
  }, { onReconnect: reload }));

  return page({
    title: 'Machines',
    actions: addButton,
  }, content);
}

// MARK: Widget

/** A machine's widget. `update(machine)` redraws it with new data, `tick()` re-evaluates the online state. */
function machineWidget(initial, { onRemove }) {
  let machine = initial;
  const title = h('h2', { class: 'machine-name' });
  const status = h('p', { class: 'machine-status' });
  const body = h('div', { class: 'machine-body' });
  const removeButton = button('Remove', {
    kind: 'plain-destructive', class: 'button button-plain-destructive button-small',
    onClick: () => onRemove(machine),
  });
  const element = card({ class: 'machine-card' },
    h('div', { class: 'machine-head' }, h('div', { class: 'machine-heading' }, title, status)),
    body,
    h('div', { class: 'card-actions' }, removeButton));

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
    replaceChildren(body, machine.report ? reportView(machine) : waitingView());
    tick();
  }

  update(initial);
  return { element, update, tick };
}

function waitingView() {
  return h('p', { class: 'card-detail' },
    'Waiting for the first heartbeat. Install the worker on this Mac with the token you got when you added it.');
}

function reportView(machine) {
  const report = machine.report;
  const max = Math.max(1, machine.maxConcurrentJobs ?? 1);
  const running = Array.isArray(report.runningJobIDs) ? report.runningJobIDs.length : 0;
  const jobs = max === 1 ? 'job' : 'jobs';
  const fact = (label, value) => h('div', { class: 'fact' },
    h('dt', { class: 'fact-label' }, label),
    h('dd', { class: 'fact-value' }, value));
  const xcodes = [...(report.xcodes ?? [])].sort((a, b) => b.version.localeCompare(a.version, 'en', { numeric: true }));
  const tools = Object.entries(report.tools ?? {}).sort(([a], [b]) => a.localeCompare(b));

  return [
    h('div', { class: 'machine-load' },
      ring(running / max, `${running} of ${max} ${jobs} running`),
      h('div', { class: 'machine-load-text' },
        h('p', { class: 'card-headline' }, `${running} of ${max} ${jobs}`),
        h('p', { class: 'card-detail' }, running === 0 ? 'Idle' : 'Building'))),
    h('dl', { class: 'facts' },
      fact('Chip', report.chip || '–'),
      fact('Performance cores', String(report.performanceCores)),
      fact('Memory', `${report.memoryGB} GB`),
      fact('Free disk', `${formatGB(report.freeDiskGB)} GB`),
      fact('Power', report.onACPower ? 'Power adapter' : 'Battery'),
      fact('macOS', report.macOSVersion || '–')),
    chipGroup('Xcode', xcodes.map((xcode) => `${xcode.version} (${xcode.build})`), 'No Xcode found'),
    chipGroup('Tools', tools.map(([name, version]) => (version ? `${name} ${version}` : name)), 'None reported'),
    report.canSignWithoutPrompt
      ? h('p', { class: 'signing signing-ok' },
        h('span', { class: 'signing-icon', 'aria-hidden': 'true' }, '✓'),
        'Can sign without a prompt')
      : h('div', { class: 'signing signing-warning' },
        h('span', { class: 'signing-icon', 'aria-hidden': 'true' }, '!'),
        h('div', null,
          h('p', { class: 'signing-title' }, 'Cannot sign without a prompt'),
          h('p', { class: 'card-note' },
            'Signing jobs skip this Mac until it can sign. As the hangar user, open Keychain Access, find the '
            + 'Apple Development private key and allow codesign under Access Control; then run hangar-worker doctor.'))),
  ];
}

function chipGroup(label, items, emptyText) {
  return h('div', { class: 'machine-group' },
    h('h3', { class: 'machine-group-title' }, label),
    items.length
      ? h('ul', { class: 'chips', 'aria-label': label }, items.map((item) => h('li', { class: 'chip' }, item)))
      : h('p', { class: 'card-note' }, emptyText));
}

function formatGB(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '–';
  return value >= 100 ? String(Math.round(value)) : value.toFixed(1);
}

// MARK: Add Machine

function openAddMachineSheet({ onAdded }) {
  const nameInput = h('input', {
    class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', autocorrect: 'off',
    placeholder: 'mac-mini-1', autofocus: true,
    onInput: () => nameInput.removeAttribute('aria-invalid'),
  });
  const maxInput = h('input', {
    class: 'input', type: 'number', inputmode: 'numeric', min: 1, max: 16, step: 1, value: '1',
    onInput: () => maxInput.removeAttribute('aria-invalid'),
  });
  sheet({
    title: 'Add Machine',
    submitOnEnter: true,
    body: h('div', { class: 'form' },
      field({ label: 'Name', hint: 'How the Mac appears in Hangar, e.g. its host name.', control: nameInput }),
      field({
        label: 'Concurrent jobs',
        hint: 'How many builds this Mac runs at once. 1 is safest; archives are heavy.',
        control: maxInput,
      })),
    actions: [
      { label: 'Cancel', kind: 'cancel' },
      {
        label: 'Add',
        kind: 'primary',
        onClick: async () => {
          const name = nameInput.value.trim();
          if (name === '') {
            nameInput.setAttribute('aria-invalid', 'true');
            nameInput.focus();
            throw new Error('Enter a name.');
          }
          const max = /^\d+$/.test(maxInput.value.trim()) ? Number(maxInput.value.trim()) : NaN;
          if (!Number.isSafeInteger(max) || max < 1) {
            maxInput.setAttribute('aria-invalid', 'true');
            maxInput.focus();
            throw new Error('Concurrent jobs must be a whole number of at least 1.');
          }
          let created;
          try {
            created = await api.post('/machines', { name, maxConcurrentJobs: max });
          } catch (error) {
            if (error.code === 'machine_exists') {
              nameInput.setAttribute('aria-invalid', 'true');
              nameInput.focus();
              throw new Error(`There is already a machine named “${name}”.`);
            }
            throw error;
          }
          onAdded(created.machine);
          // Opened after this sheet has closed, so focus returns to the page when it is dismissed.
          setTimeout(() => openTokenSheet(created.machine, created.token));
        },
      },
    ],
  });
}

/** Shows the new machine's token, once, with the commands that install the worker. */
function openTokenSheet(machine, token) {
  const origin = location.origin;
  const commands = [
    'read -rs HANGAR_WORKER_TOKEN; export HANGAR_WORKER_TOKEN',
    `scripts/worker/install-worker.sh --server ${origin}`,
  ].join('\n');

  const tokenBlock = h('pre', { class: 'code-block token-block', tabindex: '0', 'aria-label': 'Machine token' },
    h('code', null, token));
  const commandBlock = h('pre', { class: 'code-block', tabindex: '0', 'aria-label': 'Install commands' },
    h('code', null, commands));

  async function copy(text, block, what) {
    if (await copyText(text)) {
      toast(`Copied the ${what}`, 'success');
      return;
    }
    selectContents(block);
    toast(`The ${what} is selected. Press ⌘C to copy it.`, 'info');
  }

  const isLocal = LOCAL_HOSTS.has(location.hostname);
  sheet({
    title: `${machine.name} Added`,
    body: h('div', { class: 'form token-sheet' },
      h('p', { class: 'token-warning', role: 'note' }, 'Save this token now; it is not shown again.'),
      h('div', { class: 'code-field' },
        h('div', { class: 'field-label-row' },
          h('span', { class: 'field-label' }, 'Token'),
          button('Copy Token', { kind: 'plain', class: 'button button-plain button-small', onClick: () => copy(token, tokenBlock, 'token') })),
        tokenBlock),
      h('div', { class: 'code-field' },
        h('div', { class: 'field-label-row' },
          h('span', { class: 'field-label' }, 'Install the worker'),
          button('Copy Commands', { kind: 'plain', class: 'button button-plain button-small', onClick: () => copy(commands, commandBlock, 'commands') })),
        h('p', { class: 'field-hint' },
          `On ${machine.name}, as the hangar user, in a checkout of the Hangar repository. The first line waits `
          + 'for the token: paste it and press Return. Nothing is shown while you paste. To install without sudo, '
          + 'add --bin-dir ~/.local/bin to the second command.'),
        commandBlock,
        isLocal
          ? h('p', { class: 'field-hint field-error' },
            `This page is open on ${location.host}, which other Macs cannot reach. Replace it with the server’s `
            + 'tailnet address, e.g. http://hangar-server:8787.')
          : null)),
    actions: [{ label: 'Done', kind: 'primary' }],
  });
}

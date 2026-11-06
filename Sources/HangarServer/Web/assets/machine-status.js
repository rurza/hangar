// What the Machines page and the Deploy sheet say about a Mac: paused or not, whether it is the Mac the server
// runs on, and its VM builds. No imports, so the tests run it in JXA.

/** Whether `machine` is the Mac Hangar's server runs on: named like its LocalHostName, ignoring case (as `/setup`). */
function isServerMac(machine, hostName) {
  if (!hostName || !machine?.name) return false;
  return machine.name.toLowerCase() === String(hostName).toLowerCase();
}

/**
 * The load headline and the line under it, `{ headline, detail }`. `headline` is null while jobs run: the page names
 * them ("Building Legilo 88 · macOS"). `vmNotReady`: a VM Mac with no slot ready, which takes no builds; "Idle"
 * would read as available.
 */
function loadText({ running, max, paused, vmNotReady = false }) {
  const count = `${running} of ${max} ${max === 1 ? 'job' : 'jobs'} running`;
  if (!paused) {
    if (running === 0 && vmNotReady) return { headline: 'Not Taking Builds', detail: 'VM builds aren’t ready yet' };
    return { headline: running === 0 ? 'Idle' : null, detail: count };
  }
  if (running === 0) {
    return { headline: 'Builds Paused', detail: vmNotReady ? 'VM builds aren’t ready yet' : 'No new builds until resumed' };
  }
  return { headline: null, detail: `${count} · no new builds after this` };
}

/** The button that turns builds off and on again. */
function pauseButtonLabel(paused) {
  return paused ? 'Resume Builds' : 'Pause Builds';
}

/** The toast once the server said yes. `machine` is the updated machine. */
function pauseToast(machine) {
  if (!machine.paused) return `${machine.name} takes builds again`;
  const running = Array.isArray(machine.report?.runningJobIDs) ? machine.report.runningJobIDs.length : 0;
  if (running === 0) return `Builds paused on ${machine.name}`;
  return `Builds paused on ${machine.name}. ${running === 1 ? 'The build it is running finishes' : 'The builds it is running finish'} first.`;
}

/**
 * A Mac in the Deploy sheet's "where" list (a `DeployCheckMachine`): `{ detail, dot }`. A paused Mac's own reason
 * ("builds paused") is said once, up front.
 */
function deployMachineLine(machine) {
  if (!machine.online) return { detail: machine.paused ? 'Offline · builds paused' : 'Offline', dot: 'offline' };
  const waits = (machine.waits ?? []).filter((reason) => reason !== 'builds paused');
  const problems = machine.problems ?? [];
  const head = machine.paused ? 'Builds paused' : 'Online';
  if (problems.length) return { detail: `${head} · ${joinList(problems)}`, dot: 'warning' };
  if (machine.paused) {
    return { detail: `Builds paused · waits until you resume it${waits.length ? `; ${joinList(waits)}` : ''}`, dot: 'paused' };
  }
  return { detail: waits.length ? `Online · ${joinList(waits)}` : 'Online · can build it', dot: 'online' };
}

/**
 * A VM Mac's line on the Machines page (`report.vm`, a `VMReport`): `{ text, problem }`, e.g. "VM builds · 1 slot
 * (1 free) · Xcode 27.2 · network filter on". Short enough for a phone; `problem` is set only while no slot is ready.
 */
function vmLine(vm) {
  const slots = vm.slots ?? 0;
  const configured = Math.max(vm.configuredSlots ?? slots, slots);
  const noun = (count) => (count === 1 ? 'slot' : 'slots');
  let capacity;
  if (slots === 0) capacity = 'not ready';
  else if (configured > slots) capacity = `${slots} of ${configured} ${noun(configured)} (${vm.freeSlots ?? 0} free)`;
  else capacity = `${slots} ${noun(slots)} (${vm.freeSlots ?? 0} free)`;
  const versions = [...new Set((vm.images ?? []).map((image) => image.xcode).filter(Boolean))]
    .sort((a, b) => b.localeCompare(a, 'en', { numeric: true }));
  const xcode = versions.length ? `Xcode ${versions.join(', ')}` : 'no Xcode image';
  const filter = vm.networkFilter ? 'network filter on' : 'network filter off';
  return {
    text: `VM builds · ${capacity} · ${xcode} · ${filter}`,
    problem: slots === 0 ? (vm.problem || 'No VM slot is ready.') : null,
  };
}

/**
 * A VM Mac's readiness checklist (`report.vm`): `{ ready, command, rows }`. `rows` are `{ id, title, ok, required,
 * detail, command }`; `command` is the one to run first (the first failing required row's), and a row repeats a
 * command only when it is another one. A worker older than the checklist sends only its first problem, shown as one
 * row.
 */
function vmChecklist(vm) {
  const ready = (vm?.slots ?? 0) > 0;
  let rows = (Array.isArray(vm?.checks) ? vm.checks : []).map((check) => ({
    id: String(check.id ?? ''),
    title: String(check.title ?? ''),
    ok: Boolean(check.ok),
    required: check.required !== false,
    detail: String(check.detail ?? ''),
    command: check.ok ? null : check.command || null,
  }));
  if (rows.length === 0 && !ready) {
    rows = [{ id: 'problem', title: 'VM builds', ok: false, required: true, detail: vm?.problem || 'No VM slot is ready.', command: null }];
  }
  const first = rows.find((row) => row.required && !row.ok && row.command);
  const command = first?.command ?? null;
  return { ready, command, rows: rows.map((row) => (row.command === command ? { ...row, command: null } : row)) };
}

/**
 * The warning a Mac's card shows about who builds there, or null: a VM Mac builds as `builder` in a fresh VM that
 * cannot see the host, and the dedicated hangar user is the other safe case. An older worker that does not say gets
 * none. `{ title, note }`.
 */
function buildUserWarning(report) {
  const user = report?.runningUser;
  if (report?.vm || !user || user === 'hangar') return null;
  return {
    title: `Builds run as ${user}`,
    note: `A build on this Mac can read ${user}'s files. Turn on VM builds here (hangar-worker vm enable; see VM `
      + 'builds in the worker setup guide) so each build runs in a fresh VM that cannot see them.',
  };
}

/**
 * On a VM Mac, the host's Xcodes that no image was built from (by build, else by version), newest first, as the
 * card's note: `{ title, note, command }`, or null. Jobs get the images' Xcode, so a new Xcode on the Mac is used
 * only once an image is built from it.
 */
function xcodeDrift(report) {
  const vm = report?.vm;
  if (!vm) return null;
  const images = (vm.images ?? []).filter((image) => image.xcode);
  const missing = (report.xcodes ?? [])
    .filter((xcode) => !images.some((image) => (image.xcodeBuild ? image.xcodeBuild === xcode.build : image.xcode === xcode.version)))
    .sort((a, b) => b.version.localeCompare(a.version, 'en', { numeric: true }));
  if (missing.length === 0 || images.length === 0) return null;
  const newest = missing[0];
  const versions = joinList(missing.map((xcode) => xcode.version));
  let command = vm.setupCommand ?? null;
  if (command && newest.path && newest.path !== '/Applications/Xcode.app') command += ` --xcode ${shellQuote(newest.path)}`;
  return {
    title: `Xcode ${versions} on this Mac ${missing.length === 1 ? 'has' : 'have'} no VM image yet`,
    note: `Builds use the image’s Xcode until one is built from Xcode ${newest.version} (about 10 minutes). `
      + 'Pause builds first: the worker restarts at the end.',
    command,
  };
}

/** A path as a shell word: quoted only when it needs to be. */
function shellQuote(text) {
  return /^[A-Za-z0-9/._+:@%=,-]+$/.test(text) ? text : `'${text.replace(/'/g, `'\\''`)}'`;
}

/** "a", "a and b", "a, b and c". */
function joinList(items) {
  if (items.length <= 1) return items.join('');
  return `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`;
}

export { buildUserWarning, deployMachineLine, isServerMac, loadText, pauseButtonLabel, pauseToast, vmChecklist, vmLine, xcodeDrift };

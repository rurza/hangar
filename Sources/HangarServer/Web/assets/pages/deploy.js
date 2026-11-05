// The Deploy sheet: pick a branch (or type a tag or commit) and a workflow, read what the deploy will do, see
// where it runs and the build number it gets, and start the build. Deploy stays off while no Mac can run the
// workflow, so a build number is never spent on a build that would wait forever. Whether a Mac can run it is the
// server's call (`deploy-check`, the scheduler's own rules and clock), asked again as machines change.

import { api, events, seg } from '../api.js';
import { navigate } from '../router.js';
import { h, replaceChildren, sheet, spinner } from '../ui.js';
import { listText, workflowSteps } from '../workflow-summary.js';

const REF_DEBOUNCE_MS = 500;
const CHECK_INTERVAL_MS = 15_000;
const CHECK_DEBOUNCE_MS = 400;
const REF_HINT = 'Pick a branch, or type a tag or commit SHA.';

/** Error codes that are about the branch or commit and the workflow file found there. */
const REF_ERRORS = new Set([
  'ref_not_found', 'workflow_file_missing', 'invalid_workflow_file', 'unsupported_repository', 'source_host_error',
]);
/** Error codes that are about the build number. */
const NUMBER_ERRORS = new Set([
  'app_store_connect_not_configured', 'build_number_source_unavailable', 'build_number_not_integer',
]);

/** Opens the Deploy sheet for `app` (an `App`). */
export function openDeploySheet(app) {
  const base = `/apps/${seg(app.slug)}`;
  const lifetime = new AbortController();

  // State
  let workflows = null; // WorkflowsResponse for the ref in the field, or null
  let workflowsLoading = false;
  let workflowsRequest = null; // AbortController of the request in flight
  let refError = null;
  let debounce = null;
  let report = null; // NumbersReport
  let numberError = null;
  let check = null; // DeployCheck for the ref and workflow on screen, null until it answers
  let checkError = null; // the last refresh failed; `check` (if any) is the last good verdict
  let machineCount = null; // from /machines on open, so "no Mac yet" never waits for a workflow
  let checkRequest = null; // AbortController of the check in flight
  let checkTimer = null;
  let branchesLoading = true;
  let branchesHint = null; // why the branches could not be listed; stays the field's hint

  // MARK: Fields

  const refHint = h('p', { class: 'field-hint', id: 'deploy-ref-hint' }, REF_HINT);
  const branchList = h('datalist', { id: 'deploy-branches' });
  const refInput = h('input', {
    class: 'input mono', type: 'text', id: 'deploy-ref', autocomplete: 'off', spellcheck: 'false',
    autocapitalize: 'off', placeholder: 'Loading branches…', list: 'deploy-branches',
    'aria-describedby': 'deploy-ref-hint',
    onInput: () => scheduleWorkflows(),
  });
  const refField = h('div', { class: 'field' },
    h('label', { class: 'field-label', for: 'deploy-ref' }, 'Branch'),
    refInput,
    branchList,
    refHint);

  const workflowSelect = h('select', {
    class: 'input select', id: 'deploy-workflow', 'aria-describedby': 'deploy-workflow-hint',
    onChange: () => { check = null; renderWorkflowDetails(); renderWhere(); scheduleCheck(0); },
  });
  const workflowHint = h('p', { class: 'field-hint', id: 'deploy-workflow-hint' });
  const workflowField = h('div', { class: 'field' },
    h('label', { class: 'field-label', for: 'deploy-workflow' }, 'Workflow'),
    workflowSelect,
    workflowHint);

  const workflowDetails = h('div', { class: 'deploy-plan', 'aria-live': 'polite' });

  const whereOptions = h('div', { class: 'where-options' });
  const whereNotice = h('div', { class: 'deploy-notice-slot' });
  const whereField = h('fieldset', { class: 'field where-field' },
    h('legend', { class: 'field-label' }, 'Where'),
    whereNotice,
    whereOptions);

  const numberPreview = h('div', { class: 'deploy-number', 'aria-live': 'polite' });
  const reason = h('p', { class: 'deploy-reason', id: 'deploy-reason', 'aria-live': 'polite' });

  const deployAction = {
    label: 'Deploy',
    kind: 'primary',
    disabled: true,
    onClick: () => deploy(),
  };
  const handle = sheet({
    title: `Deploy ${app.name}`,
    submitOnEnter: true,
    body: h('div', { class: 'form deploy-form' }, refField, workflowField, workflowDetails, whereField, numberPreview, reason),
    actions: [{ label: 'Cancel', kind: 'cancel' }, deployAction],
    onClose: () => {
      clearTimeout(debounce);
      clearTimeout(checkTimer);
      clearInterval(ticker);
      stopEvents();
      // Only the latest requests are ever in flight; older ones were aborted when the ref changed.
      workflowsRequest?.abort();
      checkRequest?.abort();
      lifetime.abort();
    },
  });
  const deployButton = handle.element.querySelector('.sheet-actions .button-primary');
  deployButton?.setAttribute('aria-describedby', 'deploy-reason');

  // MARK: Branches

  /** The repository's branches, the default one pre-filled; a typed tag or SHA still works. */
  async function loadBranches() {
    let branches = null;
    try {
      branches = await api.get(`${base}/branches`, { signal: lifetime.signal });
    } catch (error) {
      if (error.code === 'aborted') return;
      branchesHint = `Branches could not be listed (${error.message}). Type a branch, tag or commit SHA.`;
      setRefError(null);
    }
    branchesLoading = false;
    refInput.placeholder = 'main';
    replaceChildren(branchList, (branches?.branches ?? []).map((name) => h('option', { value: name })));
    // Only when nothing was typed meanwhile.
    if (refInput.value.trim() === '') {
      refInput.value = branches?.defaultBranch ?? branches?.branches?.[0] ?? '';
      if (refInput.value) loadWorkflows();
      else { renderWorkflows(); update(); }
    }
    if (document.activeElement === handle.element || document.activeElement === document.body) refInput.focus();
  }

  // MARK: Workflows at the ref

  function scheduleWorkflows() {
    clearTimeout(debounce);
    workflowsRequest?.abort();
    workflowsRequest = null;
    // Whatever was listed belonged to the previous ref.
    workflows = null;
    check = null;
    checkRequest?.abort();
    setRefError(null);
    workflowsLoading = refInput.value.trim() !== '';
    renderWorkflows();
    update();
    if (workflowsLoading) debounce = setTimeout(loadWorkflows, REF_DEBOUNCE_MS);
  }

  async function loadWorkflows() {
    const ref = refInput.value.trim();
    if (!ref) return;
    const controller = new AbortController();
    workflowsRequest = controller;
    workflowsLoading = true;
    renderWorkflows();
    update();
    try {
      const response = await api.get(`${base}/workflows?ref=${encodeURIComponent(ref)}`, { signal: controller.signal });
      if (workflowsRequest !== controller) return;
      workflows = response;
    } catch (error) {
      if (workflowsRequest !== controller || error.code === 'aborted') return;
      workflows = null;
      setRefError(error.message, error.code === 'ref_not_found');
    }
    workflowsRequest = null;
    workflowsLoading = false;
    renderWorkflows();
    scheduleCheck(0);
  }

  function setRefError(message, invalid = Boolean(message)) {
    refError = message;
    refHint.textContent = message ?? branchesHint ?? REF_HINT;
    refHint.classList.toggle('field-error', Boolean(message));
    if (invalid) refInput.setAttribute('aria-invalid', 'true');
    else refInput.removeAttribute('aria-invalid');
  }

  function renderWorkflows() {
    const previous = workflowSelect.value;
    const names = workflows && !workflowsLoading ? Object.keys(workflows.workflows?.workflows ?? {}).sort() : [];
    if (names.length === 0) {
      const placeholder = workflowsLoading || branchesLoading ? 'Loading…' : 'No workflows';
      replaceChildren(workflowSelect, h('option', { value: '' }, placeholder));
      workflowSelect.disabled = true;
    } else {
      replaceChildren(workflowSelect, names.map((name) => h('option', { value: name }, name)));
      workflowSelect.value = names.includes(previous) ? previous : names[0];
      workflowSelect.disabled = false;
    }
    if (workflowsLoading) {
      workflowHint.textContent = 'Reading the workflow at this branch…';
    } else if (workflows) {
      const commit = String(workflows.commit ?? '').slice(0, 7);
      workflowHint.textContent = workflows.source === 'hangar'
        ? `Defined in Hangar · builds commit ${commit}`
        : `From .hangar.yml at ${commit}`;
    } else {
      workflowHint.textContent = refError ? 'Fix the branch or commit to see its workflows.' : '';
    }
    renderWorkflowDetails();
  }

  function selectedWorkflow() {
    if (!workflows || workflowsLoading || !workflowSelect.value) return null;
    return workflows.workflows?.workflows?.[workflowSelect.value] ?? null;
  }

  /** What the deploy does, as a short numbered list of sentences. */
  function renderWorkflowDetails() {
    const workflow = selectedWorkflow();
    if (!workflow) {
      replaceChildren(workflowDetails);
      workflowDetails.hidden = true;
      return;
    }
    workflowDetails.hidden = false;
    replaceChildren(workflowDetails,
      h('p', { class: 'deploy-plan-title' }, 'What happens'),
      h('ol', { class: 'deploy-plan-steps' }, workflowSteps(workflow).map((step) => h('li', null, step))));
  }

  // MARK: Machines

  /** Asks the server again after `delay` ms (debounced): on open, a new ref or workflow, a machine event, a tick. */
  function scheduleCheck(delay = CHECK_DEBOUNCE_MS) {
    clearTimeout(checkTimer);
    checkTimer = setTimeout(loadCheck, delay);
    update();
  }

  /**
   * The scheduler's verdict on every machine. Always asked without a pin, so every Mac can be offered; a pinned
   * Mac's own verdict is its `problems` in the answer, which are the same reasons a pinned check would give.
   */
  async function loadCheck() {
    const workflow = selectedWorkflow();
    const ref = refInput.value.trim();
    checkRequest?.abort();
    if (!workflow || !ref) {
      checkRequest = null;
      renderWhere();
      update();
      return;
    }
    const controller = new AbortController();
    checkRequest = controller;
    // The commit /workflows resolved: the server then asks GitHub nothing, however often the sheet checks.
    const query = new URLSearchParams({ workflow: workflowSelect.value, ref });
    if (workflows?.commit) query.set('commit', workflows.commit);
    try {
      const answer = await api.get(`${base}/deploy-check?${query}`, { signal: controller.signal });
      if (checkRequest !== controller) return;
      check = answer;
      machineCount = answer.machines.length;
      checkError = null;
    } catch (error) {
      if (checkRequest !== controller || error.code === 'aborted') return;
      // A failed refresh keeps the last good verdict; only without one does Deploy wait for an answer.
      checkError = error.message;
    }
    checkRequest = null;
    renderWhere();
    update();
  }

  function selectedMachineID() {
    return whereOptions.querySelector('input:checked')?.value ?? '';
  }

  /** "Archive – iOS · LegiloMobile: mini (offline)" per blocked action. */
  function blockingText(entries) {
    return entries.map((entry) => {
      const machines = Object.entries(entry.reasons ?? {}).sort(([a], [b]) => a.localeCompare(b))
        .map(([name, reasons]) => `${name} (${reasons.join(', ')})`);
      return `${entry.action}: ${machines.length ? listText(machines) : 'no Mac'}`;
    }).join('; ');
  }

  /** Why no machine can run the deploy (with what to do), or null. Read from the server's answer only. */
  function machineBlocker() {
    if (!check && machineCount === 0) {
      return { text: 'No Mac can run builds yet. Add one, then deploy.', link: ['Add a Mac', '/machines?add=1'] };
    }
    if (!check) return null;
    if (check.machines.length === 0) {
      return { text: 'No Mac can run builds yet. Add one, then deploy.', link: ['Add a Mac', '/machines?add=1'] };
    }
    const pinned = check.machines.find((machine) => machine.id === selectedMachineID());
    if (pinned && pinned.problems.length) {
      return { text: `${pinned.name} can’t run this build: ${listText(pinned.problems)}.`, link: ['Open Machines', '/machines'] };
    }
    if (!pinned && !check.canDeploy) {
      return { text: `No Mac can run this build now. ${blockingText(check.blocking)}.`, link: ['Open Machines', '/machines'] };
    }
    return null;
  }

  /** Waits the build will have (busy, low disk), which do not block it. */
  function waitText() {
    if (!check || machineBlocker()) return null;
    const pinned = check.machines.find((machine) => machine.id === selectedMachineID());
    if (pinned) return pinned.waits.length ? `It will wait: ${pinned.name} is ${listText(pinned.waits)}.` : null;
    return check.warnings.length ? `It will wait for a free Mac: ${blockingText(check.warnings)}.` : null;
  }

  function renderWhere() {
    const previous = selectedMachineID();
    const option = (value, title, detail, dot) => h('label', { class: 'where-option' },
      h('input', { type: 'radio', name: 'deploy-where', value, checked: value === previous, class: 'where-radio', onChange: () => update() }),
      // Every row keeps the dot's column, so the titles line up.
      h('span', { class: ['online-dot', dot ?? 'none'], 'aria-hidden': 'true' }),
      h('span', { class: 'where-text' },
        h('span', { class: 'where-title' }, title),
        h('span', { class: 'where-detail' }, detail)));
    const machines = check?.machines ?? [];
    const able = machines.filter((machine) => machine.online && machine.problems.length === 0);
    const automaticDetail = able.length === 0 ? 'The first free Mac that can build it.'
      : able.length === 1 ? `Runs on ${able[0].name}, the Mac that can build it.`
        : `The first free of ${listText(able.map((machine) => machine.name))}.`;
    const noMachines = check ? machines.length === 0 : machineCount === 0;
    // Nothing to judge yet: no branch, no workflow, or the branch failed. Say so instead of spinning.
    const waitingFor = !check && !checkError && !noMachines
      ? (workflowsLoading || branchesLoading ? null
        : !refInput.value.trim() ? 'Pick a branch to see which Mac can run it.'
          : refError || !selectedWorkflow() ? 'Which Mac can run it shows once there is a workflow to deploy.' : null)
      : null;
    if (noMachines) {
      replaceChildren(whereOptions);
      whereOptions.hidden = true;
    } else {
      whereOptions.hidden = false;
      replaceChildren(whereOptions,
        option('', 'Automatic', automaticDetail),
        machines.map((machine) => {
          const detail = !machine.online ? 'Offline'
            : machine.problems.length ? `Online · ${listText(machine.problems)}`
              : machine.waits.length ? `Online · ${listText(machine.waits)}` : 'Online · can build it';
          const dot = !machine.online ? 'offline' : machine.problems.length ? 'warning' : 'online';
          return option(machine.id, machine.name, detail, dot);
        }),
        waitingFor ? h('p', { class: 'field-hint' }, waitingFor) : null,
        !check && !checkError && !waitingFor ? h('p', { class: 'field-hint where-loading' }, spinner('Checking the machines'), 'Checking the machines…') : null,
        checkError ? h('p', { class: ['field-hint', !check && 'field-error'] }, check
          ? `Couldn’t refresh (${checkError}); showing the last check.`
          : `The machines could not be checked: ${checkError}`) : null);
      if (!whereOptions.querySelector('input:checked')) whereOptions.querySelector('input').checked = true;
    }
    renderNotice();
  }

  function renderNotice() {
    const blocker = machineBlocker();
    const wait = waitText();
    replaceChildren(whereNotice, blocker
      ? h('div', { class: 'deploy-notice', role: 'note' },
        h('p', null, blocker.text),
        h('a', { href: blocker.link[1], 'data-link': true, class: 'button button-secondary button-small' }, blocker.link[0]))
      : wait ? h('p', { class: 'field-hint' }, wait) : null);
  }

  // MARK: Build number

  async function loadNumber() {
    replaceChildren(numberPreview, h('span', { class: 'deploy-number-label' }, 'Build number'), spinner('Loading the build number'));
    report = null;
    numberError = null;
    update();
    try {
      report = await api.get(`${base}/numbers`, { signal: lifetime.signal });
    } catch (error) {
      if (error.code === 'aborted') return;
      numberError = error.message;
    }
    renderNumber();
    update();
  }

  function renderNumber() {
    if (numberError) {
      replaceChildren(numberPreview,
        h('span', { class: 'deploy-number-label' }, 'Build number'),
        h('span', { class: 'inline-error-message' }, numberError),
        h('button', { type: 'button', class: 'button button-plain button-small', onClick: loadNumber }, 'Try Again'));
      return;
    }
    if (!report) return;
    replaceChildren(numberPreview,
      h('span', { class: 'deploy-number-label' }, 'Build number'),
      h('span', { class: 'deploy-number-value' }, String(report.next)),
      report.inFlight ? h('span', { class: 'field-hint' }, 'Another build is in progress with an earlier number.') : null);
  }

  // MARK: Deploy

  /** Why Deploy is unavailable, or null when it can run. */
  function blocker() {
    if (branchesLoading && !refInput.value.trim()) return 'Loading the branches…';
    if (!refInput.value.trim()) return 'Enter a branch or commit to deploy.';
    if (workflowsLoading) return 'Reading the workflow at this branch…';
    if (refError) return 'Fix the branch or commit first.';
    const workflow = selectedWorkflow();
    if (!workflow) return 'There is no workflow to deploy.';
    const gated = (workflow.postActions ?? []).find((spec) => spec.requiresApproval);
    if (gated) return `The post-action “${gated.name}” needs approval, which Hangar does not support yet.`;
    if (machineBlocker()) return 'No Mac can run this build now (see Where), so Deploy stays off and no build number is used.';
    if (checkError && !check) return 'Hangar could not check which Mac can run it (see above).';
    if (!check) return 'Checking which Mac can run it…';
    if (numberError) return 'Hangar cannot pick a build number (see above).';
    if (!report) return 'Waiting for the build number…';
    return null;
  }

  function update() {
    renderNotice();
    const why = blocker();
    deployAction.disabled = Boolean(why);
    if (deployButton) deployButton.disabled = deployAction.disabled;
    // The live region stays in the DOM so screen readers announce each new reason.
    reason.textContent = why ?? '';
  }

  async function deploy() {
    if (blocker()) {
      // Say why, rather than leave a button that does nothing.
      update();
      return false;
    }
    const request = { app: app.slug, workflow: workflowSelect.value, ref: refInput.value.trim() };
    const machine = selectedMachineID();
    if (machine) request.machine = machine;
    let build;
    try {
      build = await api.post('/builds', request);
    } catch (error) {
      if (REF_ERRORS.has(error.code)) {
        workflows = null;
        setRefError(error.message, error.code === 'ref_not_found');
        renderWorkflows();
        update();
        refInput.focus();
        return false;
      }
      if (NUMBER_ERRORS.has(error.code)) {
        numberError = error.message;
        renderNumber();
        update();
        return false;
      }
      throw error;
    }
    // Leaving the page closes the sheet.
    navigate(`/builds/${seg(build.id)}`);
    return true;
  }

  // Machines come and go: ask again on every machine event, and on a tick so a Mac that went quiet is noticed.
  // Heartbeats don't trigger a check (the tick covers them); a Mac that is new to the sheet does.
  const stopEvents = events((event) => {
    if (event.type !== 'machine' || !event.machine) return;
    const known = check ? check.machines.some((machine) => machine.id.toLowerCase() === String(event.machine.id).toLowerCase()) : machineCount > 0;
    if (!known) scheduleCheck();
  }, { onReconnect: () => scheduleCheck() });
  api.get('/machines', { signal: lifetime.signal }).then((list) => {
    machineCount = list.length;
    renderWhere();
    update();
  }, () => {});
  const ticker = setInterval(() => scheduleCheck(0), CHECK_INTERVAL_MS);

  renderWorkflows();
  renderWhere();
  update();
  loadBranches();
  loadNumber();
  return handle;
}

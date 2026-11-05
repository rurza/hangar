// The Deploy sheet: pick a branch (or type a tag or commit) and a workflow, read what the deploy will do, see
// where it runs and the build number it gets, and start the build. Deploy stays off while no Mac can run the
// workflow, so a build number is never spent on a build that would wait forever.

import { api, seg } from '../api.js';
import { navigate } from '../router.js';
import { h, relativeTime, replaceChildren, sheet, spinner } from '../ui.js';
import { listText, machineOnline, machineProblems, workflowSteps } from '../workflow-summary.js';

const REF_DEBOUNCE_MS = 500;
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
  let machines = null; // [Machine], null until listed
  let machinesError = null;
  let branchesLoading = true;

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
    onChange: () => { renderWorkflowDetails(); renderWhere(); update(); },
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
      // Only the latest workflows request is ever in flight; older ones were aborted when the ref changed.
      workflowsRequest?.abort();
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
      setRefError(null);
      refHint.textContent = `Branches could not be listed (${error.message}). Type a branch, tag or commit SHA.`;
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
    renderWhere();
    update();
  }

  function setRefError(message, invalid = Boolean(message)) {
    refError = message;
    refHint.textContent = message ?? REF_HINT;
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

  async function loadMachines() {
    try {
      machines = await api.get('/machines', { signal: lifetime.signal });
      machines.sort((a, b) => a.name.localeCompare(b.name));
      machinesError = null;
    } catch (error) {
      if (error.code === 'aborted') return;
      machines = [];
      machinesError = error.message;
    }
    renderWhere();
    update();
  }

  /** Each machine with whether it is online and what keeps it from the selected workflow. */
  function machineStates() {
    const workflow = selectedWorkflow();
    const now = new Date();
    return (machines ?? []).map((machine) => ({
      machine,
      online: machineOnline(machine, now),
      problems: workflow ? machineProblems(machine, workflow) : [],
    }));
  }

  /** Why no machine can run the deploy (with what to do), or null. */
  function machineBlocker() {
    if (machines === null || machinesError) return null;
    if (machines.length === 0) {
      return { text: 'No Mac can run builds yet. Add one, then deploy.', link: ['Add a Mac', '/machines?add=1'] };
    }
    if (!selectedWorkflow()) return null;
    const states = machineStates();
    const pinned = whereOptions.querySelector('input:checked')?.value;
    const pick = pinned ? states.filter((state) => state.machine.id === pinned) : states;
    const able = pick.filter((state) => state.problems.length === 0);
    if (able.length === 0) {
      const why = pick.map((state) => `${state.machine.name} (${listText(state.problems)})`);
      return {
        text: `${pinned ? 'This Mac can’t' : 'No Mac can'} build this workflow: ${listText(why)}.`,
        link: ['Open Machines', '/machines'],
      };
    }
    if (!able.some((state) => state.online)) {
      const names = listText(able.map((state) => state.machine.name));
      const seen = able.map((state) => state.machine.lastSeenAt).filter(Boolean).sort().at(-1);
      return {
        text: `${names} ${able.length === 1 ? 'is' : 'are'} offline${seen ? ` (last seen ${relativeTime(seen)})` : ''}. `
          + 'Start the worker on it, then deploy.',
        link: ['Open Machines', '/machines'],
      };
    }
    return null;
  }

  function renderWhere() {
    const previous = whereOptions.querySelector('input:checked')?.value ?? '';
    const states = machineStates();
    const workflow = selectedWorkflow();
    const able = states.filter((state) => state.online && state.problems.length === 0);
    const option = (value, title, detail, dot) => h('label', { class: 'where-option' },
      h('input', { type: 'radio', name: 'deploy-where', value, checked: value === previous, class: 'where-radio', onChange: () => update() }),
      // Every row keeps the dot's column, so the titles line up.
      h('span', { class: ['online-dot', dot ?? 'none'], 'aria-hidden': 'true' }),
      h('span', { class: 'where-text' },
        h('span', { class: 'where-title' }, title),
        h('span', { class: 'where-detail' }, detail)));
    const automaticDetail = !workflow || able.length === 0
      ? 'The first free Mac that can build it.'
      : able.length === 1 ? `Runs on ${able[0].machine.name}, the Mac that can build it.`
        : `The first free of ${listText(able.map((state) => state.machine.name))}.`;
    if (machines !== null && machines.length === 0) {
      replaceChildren(whereOptions);
      whereOptions.hidden = true;
    } else {
      whereOptions.hidden = false;
      replaceChildren(whereOptions,
        option('', 'Automatic', automaticDetail),
        states.map(({ machine, online, problems }) => {
          const detail = !online
            ? `Offline${machine.lastSeenAt ? ` · seen ${relativeTime(machine.lastSeenAt)}` : ' · never connected'}`
            : problems.length ? `Online · ${listText(problems)}` : 'Online · can build it';
          return option(machine.id, machine.name, detail, online ? (problems.length ? 'warning' : 'online') : 'offline');
        }),
        machines === null ? h('p', { class: 'field-hint where-loading' }, spinner('Loading machines'), 'Loading machines…') : null,
        machinesError ? h('p', { class: 'field-hint field-error' }, `Machines could not be listed: ${machinesError}`) : null);
      if (!whereOptions.querySelector('input:checked')) whereOptions.querySelector('input').checked = true;
    }
    renderNotice();
  }

  function renderNotice() {
    const blocker = machineBlocker();
    replaceChildren(whereNotice, blocker
      ? h('div', { class: 'deploy-notice', role: 'note' },
        h('p', null, blocker.text),
        h('a', { href: blocker.link[1], 'data-link': true, class: 'button button-secondary button-small' }, blocker.link[0]))
      : null);
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
    if (machines === null) return 'Checking the machines…';
    const machine = machineBlocker();
    if (machine) return 'No Mac can run this build now, so Deploy is off and no build number is used.';
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
    if (blocker()) return false;
    const request = { app: app.slug, workflow: workflowSelect.value, ref: refInput.value.trim() };
    const machine = whereOptions.querySelector('input:checked')?.value;
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

  renderWorkflows();
  renderWhere();
  update();
  loadBranches();
  loadMachines();
  loadNumber();
  return handle;
}

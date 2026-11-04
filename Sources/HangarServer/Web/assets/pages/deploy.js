// The Deploy sheet: pick a workflow at a branch or commit, see the build number it gets and where it runs, and
// start the build.

import { api, seg } from '../api.js';
import { navigate } from '../router.js';
import { h, replaceChildren, sheet, spinner } from '../ui.js';
import { actionLabel, isOnline } from './build.js';

const REF_DEBOUNCE_MS = 500;

/** Error codes that are about the branch or commit and the workflow file found there. */
const REF_ERRORS = new Set([
  'ref_not_found', 'workflow_file_missing', 'invalid_workflow_file', 'unsupported_repository', 'source_host_error',
]);
/** Error codes that are about the build number. */
const NUMBER_ERRORS = new Set([
  'app_store_connect_not_configured', 'build_number_source_unavailable', 'build_number_not_integer',
]);

/** "TestFlight · groups: Internal · wait for processing" for one post-action of a workflow. */
function postActionSummary(spec) {
  if (spec.name !== 'testflight') return spec.requiresApproval ? `${spec.name} · needs approval` : spec.name;
  const settings = spec.settings ?? {};
  const parts = ['TestFlight'];
  const groups = Array.isArray(settings.groups) ? settings.groups : [];
  if (groups.length) parts.push(`groups: ${groups.join(', ')}`);
  if (settings['wait-for-processing'] ?? true) parts.push('wait for processing');
  if (settings['submit-for-external-review']) parts.push('submit for external review');
  if (spec.requiresApproval) parts.push('needs approval');
  return parts.join(' · ');
}

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
  let machines = []; // [Machine]

  // MARK: Fields

  const refHint = h('p', { class: 'field-hint', id: 'deploy-ref-hint' }, 'A branch, tag or commit SHA.');
  const refInput = h('input', {
    class: 'input mono', type: 'text', id: 'deploy-ref', value: 'main', autocomplete: 'off', spellcheck: 'false',
    autocapitalize: 'off', 'aria-describedby': 'deploy-ref-hint',
    onInput: () => scheduleWorkflows(),
  });
  const refField = h('div', { class: 'field' },
    h('label', { class: 'field-label', for: 'deploy-ref' }, 'Branch or commit'),
    refInput,
    refHint);

  const workflowSelect = h('select', {
    class: 'input select', id: 'deploy-workflow', 'aria-describedby': 'deploy-workflow-hint',
    onChange: () => { renderWorkflowDetails(); update(); },
  });
  const workflowHint = h('p', { class: 'field-hint', id: 'deploy-workflow-hint' });
  const workflowDetails = h('div', { class: 'deploy-details' });
  const workflowField = h('div', { class: 'field' },
    h('label', { class: 'field-label', for: 'deploy-workflow' }, 'Workflow'),
    workflowSelect,
    workflowHint,
    workflowDetails);

  const whereOptions = h('div', { class: 'where-options' });
  const whereField = h('fieldset', { class: 'field where-field' },
    h('legend', { class: 'field-label' }, 'Where'),
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
    body: h('div', { class: 'form deploy-form' }, refField, workflowField, whereField, numberPreview, reason),
    actions: [{ label: 'Cancel', kind: 'cancel' }, deployAction],
    onClose: () => {
      clearTimeout(debounce);
      lifetime.abort();
    },
  });
  const deployButton = handle.element.querySelector('.sheet-actions .button-primary');
  deployButton?.setAttribute('aria-describedby', 'deploy-reason');

  // MARK: Workflows at the ref

  function scheduleWorkflows() {
    clearTimeout(debounce);
    workflowsRequest?.abort();
    workflowsRequest = null;
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
    lifetime.signal.addEventListener('abort', () => controller.abort(), { once: true });
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
    update();
  }

  function setRefError(message, invalid = Boolean(message)) {
    refError = message;
    refHint.textContent = message ?? 'A branch, tag or commit SHA.';
    refHint.classList.toggle('field-error', Boolean(message));
    if (invalid) refInput.setAttribute('aria-invalid', 'true');
    else refInput.removeAttribute('aria-invalid');
  }

  function renderWorkflows() {
    const previous = workflowSelect.value;
    const names = workflows && !workflowsLoading ? Object.keys(workflows.workflows?.workflows ?? {}).sort() : [];
    if (names.length === 0) {
      const placeholder = workflowsLoading ? 'Loading…' : 'No workflows';
      replaceChildren(workflowSelect, h('option', { value: '' }, placeholder));
      workflowSelect.disabled = true;
    } else {
      replaceChildren(workflowSelect, names.map((name) => h('option', { value: name }, name)));
      workflowSelect.value = names.includes(previous) ? previous : names[0];
      workflowSelect.disabled = false;
    }
    if (workflowsLoading) {
      workflowHint.textContent = 'Reading the workflow file…';
    } else if (workflows) {
      const commit = String(workflows.commit ?? '').slice(0, 7);
      workflowHint.textContent = workflows.source === 'hangar'
        ? `Defined in Hangar · commit ${commit}`
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

  function renderWorkflowDetails() {
    const workflow = selectedWorkflow();
    if (!workflow) {
      replaceChildren(workflowDetails);
      return;
    }
    const detail = (label, value) => h('div', { class: 'fact' },
      h('dt', { class: 'fact-label' }, label),
      h('dd', { class: 'fact-value deploy-fact-value' }, value));
    const postActions = workflow.postActions ?? [];
    replaceChildren(workflowDetails, h('dl', { class: 'facts' },
      detail('Builds', h('ul', { class: 'plain-list' },
        (workflow.actions ?? []).map((action) => h('li', null, actionLabel(action))))),
      detail('Then', postActions.length
        ? h('ul', { class: 'plain-list' }, postActions.map((spec) => h('li', null, postActionSummary(spec))))
        : 'Nothing else'),
      detail('Xcode', workflow.xcode ?? '–')));
  }

  // MARK: Machines

  async function loadMachines() {
    try {
      machines = await api.get('/machines', { signal: lifetime.signal });
      machines.sort((a, b) => a.name.localeCompare(b.name));
    } catch (error) {
      if (error.code === 'aborted') return;
      machines = [];
      renderWhere(`Machines could not be listed: ${error.message}`);
      return;
    }
    renderWhere();
  }

  function renderWhere(note) {
    const previous = whereOptions.querySelector('input:checked')?.value ?? '';
    const now = new Date();
    const option = (value, title, detail, online) => h('label', { class: 'where-option' },
      h('input', { type: 'radio', name: 'deploy-where', value, checked: value === previous, class: 'where-radio' }),
      online === undefined
        ? null
        : h('span', { class: ['online-dot', online ? 'online' : 'offline'], 'aria-hidden': 'true' }),
      h('span', { class: 'where-text' },
        h('span', { class: 'where-title' }, title),
        h('span', { class: 'where-detail' }, detail)));
    replaceChildren(whereOptions,
      option('', 'Automatic', 'The first machine that can build it.'),
      machines.map((machine) => {
        const online = isOnline(machine, now);
        return option(machine.id, machine.name, online ? 'Online' : 'Offline · the build waits for it', online);
      }),
      note ? h('p', { class: 'field-hint' }, note) : null);
    if (!whereOptions.querySelector('input:checked')) whereOptions.querySelector('input').checked = true;
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
    if (!refInput.value.trim()) return 'Enter a branch or commit to deploy.';
    if (workflowsLoading) return 'Reading the workflow file at this branch or commit…';
    if (refError) return 'Fix the branch or commit first.';
    const workflow = selectedWorkflow();
    if (!workflow) return 'There is no workflow to deploy.';
    const gated = (workflow.postActions ?? []).find((spec) => spec.requiresApproval);
    if (gated) return `The post-action “${gated.name}” needs approval, which Hangar does not support yet.`;
    if (numberError) return 'Hangar cannot pick a build number (see above).';
    if (!report) return 'Waiting for the build number…';
    return null;
  }

  function update() {
    const why = blocker();
    deployAction.disabled = Boolean(why);
    if (deployButton) deployButton.disabled = deployAction.disabled;
    reason.textContent = why ?? '';
    reason.hidden = !why;
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
  workflowsLoading = true;
  loadWorkflows();
  loadMachines();
  loadNumber();
  return handle;
}

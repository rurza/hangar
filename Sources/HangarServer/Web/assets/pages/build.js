// The build detail page (`/builds/:id`): the build's header, one card per job with its steps, outputs and
// artifacts, and the log, all kept live from the event and log streams.

import { api, ApiError, events, followLog, seg } from '../api.js';
import {
  button, card, confirm, duration, emptyState, h, page, relativeTime, replaceChildren, section, spinner, statusBadge,
  svg, toast,
} from '../ui.js';
import { appIcon } from './apps.js';

const PLATFORM_NAMES = { ios: 'iOS', macos: 'macOS', visionos: 'visionOS', tvos: 'tvOS', watchos: 'watchOS' };
const ONLINE_WINDOW_MS = 90_000;
const LOG_LINE_CAP = 5000;
const TERMINAL = new Set(['succeeded', 'failed', 'cancelled']);

const STEP_LABELS = {
  checkout: 'Check out',
  'post-clone': 'Post-clone script',
  'pre-xcodebuild': 'Pre-xcodebuild script',
  archive: 'Archive',
  test: 'Test',
  stamp: 'Stamp build number',
  export: 'Export',
  'post-xcodebuild': 'Post-xcodebuild script',
  'upload-artifacts': 'Upload artifacts',
  cleanup: 'Clean up',
  'post-action:testflight': 'TestFlight',
};

const OUTPUT_LABELS = {
  'testflight.processingState': 'TestFlight build state',
  'testflight.buildID': 'TestFlight build ID',
};

// MARK: Shared helpers

/** "Archive – iOS · LegiloMobile" or "Test – iOS · LegiloTests" for a `WorkflowAction`. */
export function actionLabel(action) {
  const kind = action?.kind === 'test' ? 'Test' : 'Archive';
  return `${kind} – ${PLATFORM_NAMES[action?.platform] ?? action?.platform ?? '?'} · ${action?.scheme ?? '?'}`;
}

/** A test job's results from its `test.*` outputs, or null before they are in. */
function testResults(job) {
  const outputs = job.outputs ?? {};
  if (job.action?.kind !== 'test' || outputs['test.total'] === undefined) return null;
  let failures = [];
  try {
    const parsed = JSON.parse(outputs['test.failures'] ?? '[]');
    if (Array.isArray(parsed)) failures = parsed.filter((failure) => failure && typeof failure.name === 'string');
  } catch {
    // A list that cannot be read leaves just the totals.
  }
  const count = (key) => outputs[key] ?? '0';
  return { totals: `${count('test.passed')} passed · ${count('test.failed')} failed · ${count('test.skipped')} skipped`, failures };
}

function testsView(job) {
  const results = testResults(job);
  if (!results) return null;
  return h('div', { class: 'job-tests' },
    h('h3', { class: 'job-subtitle' }, 'Tests'),
    h('p', { class: 'test-totals' }, results.totals),
    results.failures.length
      ? h('ul', { class: 'test-failures', 'aria-label': 'Failing tests' }, results.failures.map((failure) => h('li', { class: 'test-failure' },
        h('span', { class: 'test-failure-name mono' }, failure.name),
        failure.message ? h('span', { class: 'test-failure-message' }, String(failure.message)) : null)))
      : null);
}

/** A machine is online when it was seen within the last 90 seconds. */
export function isOnline(machine, now = new Date()) {
  if (!machine?.lastSeenAt) return false;
  const seen = new Date(machine.lastSeenAt);
  return !Number.isNaN(seen.getTime()) && now - seen <= ONLINE_WINDOW_MS;
}

export function isTerminal(status) {
  return TERMINAL.has(status);
}

/** When a build started (its first job's start, else its creation) and when it ended (null while not finished). */
export function buildTiming(build) {
  const starts = (build.jobs ?? []).map((job) => job.startedAt).filter(Boolean).sort();
  return { start: starts[0] ?? null, created: build.createdAt, end: build.finishedAt ?? null };
}

/** The build's duration: "–" before any job started, ticking while it runs. */
export function buildDuration(build) {
  const { start, end } = buildTiming(build);
  if (!start) return '–';
  return duration(start, isTerminal(build.status) ? (end ?? start) : null);
}

/** "12.3 MB", in decimal units like Finder. */
export function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return '–';
  if (bytes < 1000) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = bytes;
  let unit = -1;
  do {
    value /= 1000;
    unit += 1;
  } while (value >= 1000 && unit < units.length - 1);
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`;
}

function shortSHA(commit) {
  return String(commit ?? '').slice(0, 7);
}

function stepLabel(name) {
  if (STEP_LABELS[name]) return STEP_LABELS[name];
  if (name.startsWith('post-action:')) return name.slice('post-action:'.length);
  return name;
}

const clock = new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });

function logTime(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? '--:--:--' : clock.format(date);
}

function stepIcon(status) {
  const paths = {
    succeeded: [['path', { d: 'M7 12.5l3.2 3.2L17 9' }]],
    failed: [['path', { d: 'M8.5 8.5l7 7M15.5 8.5l-7 7' }]],
    skipped: [['path', { d: 'M8 12h8' }]],
    pending: [],
    running: [],
  };
  return h('span', { class: ['step-icon', `step-${status}`], 'aria-hidden': 'true' },
    svg('svg', { viewBox: '0 0 24 24' }, (paths[status] ?? []).map(([tag, attrs]) => svg(tag, attrs))));
}

// MARK: Page

/** The `/builds/:id` route. */
export async function buildPage(params, context) {
  const { signal } = context;
  let build;
  try {
    build = await api.get(`/builds/${seg(params.id)}`, { signal });
  } catch (error) {
    if (error instanceof ApiError && (error.code === 'build_not_found' || error.status === 400)) {
      return page({ title: 'Build Not Found' }, emptyState({
        title: 'This build does not exist',
        message: 'It may have been removed with its app.',
        action: h('a', { href: '/builds', 'data-link': true, class: 'button button-primary' }, 'Go to History'),
      }));
    }
    throw error;
  }
  // The page may have been left while the request ran: start no timers or streams for it.
  if (signal.aborted) return null;
  const [appResult, machinesResult] = await Promise.allSettled([
    api.get(`/apps/${seg(build.appID)}`, { signal }),
    api.get('/machines', { signal }),
  ]);
  if (signal.aborted) return null;
  const app = appResult.status === 'fulfilled' ? appResult.value : null;
  const machines = new Map(machinesResult.status === 'fulfilled' ? machinesResult.value.map((m) => [m.id, m]) : []);
  const appName = app?.name ?? 'Unknown app';

  // Running durations tick every second; each render registers its live elements here.
  let tickers = [];
  const timer = setInterval(() => {
    tickers = tickers.filter((tick) => tick());
  }, 1000);
  context.onCleanup(() => clearInterval(timer));
  /** Keeps `element`'s text at `text()` every second while it is on the page. */
  function live(element, text) {
    element.textContent = text();
    tickers.push(() => {
      if (!element.isConnected) return false;
      element.textContent = text();
      return true;
    });
    return element;
  }

  // MARK: Header

  const meta = h('div', { class: 'build-meta' });
  const actions = h('div', { class: 'build-actions' });

  function renderHeader() {
    const { start, created } = buildTiming(build);
    replaceChildren(meta,
      statusBadge(build.status),
      live(h('span', { class: 'build-meta-item' }),
        () => (start ? `Started ${relativeTime(start)}` : `Created ${relativeTime(created)}`)),
      start
        ? live(h('span', { class: 'build-meta-item build-duration' }), () => buildDuration(build))
        : null);
    replaceChildren(actions, isTerminal(build.status)
      ? null
      : button('Cancel Build', { kind: 'destructive', onClick: cancel }));
  }

  async function cancel() {
    const confirmed = await confirm({
      title: `Cancel Build ${build.buildNumber}?`,
      message: 'Queued jobs are dropped and running ones are stopped. The build number stays used.',
      confirmLabel: 'Cancel Build',
      destructive: true,
    });
    if (!confirmed) return;
    try {
      apply(await api.post(`/builds/${seg(build.id)}/cancel`, undefined, { signal }));
      toast(`Cancelling build ${build.buildNumber}`);
    } catch (error) {
      if (error.code !== 'aborted') toast(error.message, 'error');
    }
  }

  // MARK: Jobs

  const jobsElement = h('div', { class: 'job-cards' });
  const cards = new Map(); // job id → job card

  function renderJobs() {
    for (const job of build.jobs) {
      let jobCard = cards.get(job.id);
      if (!jobCard) {
        jobCard = jobCardView(job, { machines, live, signal });
        cards.set(job.id, jobCard);
      }
      jobCard.update(job);
    }
    replaceChildren(jobsElement, build.jobs.map((job) => cards.get(job.id).element));
  }

  // MARK: Updates

  function apply(updated) {
    build = updated;
    renderHeader();
    renderJobs();
    log.updateJobs(build.jobs);
  }

  function applyJob(job) {
    const index = build.jobs.findIndex((existing) => existing.id === job.id);
    if (index < 0) return;
    build.jobs[index] = job;
    cards.get(job.id)?.update(job);
    log.updateJobs(build.jobs);
  }

  const log = logPanel(build.jobs, context);

  context.onCleanup(events((event) => {
    if (event.type === 'build' && event.build?.id === build.id) apply(event.build);
    else if (event.type === 'job' && event.job?.buildID === build.id) applyJob(event.job);
    else if (event.type === 'machine' && event.machine) machines.set(event.machine.id, event.machine);
  }, {
    onReconnect: () => {
      api.get(`/builds/${seg(build.id)}`, { signal }).then(apply, () => {});
    },
  }));

  renderHeader();
  renderJobs();

  const view = page({
    title: `Build ${build.buildNumber}`,
    subtitle: h('span', { class: 'build-subtitle' },
      app
        ? h('a', { href: `/apps/${seg(app.slug)}`, 'data-link': true }, appName)
        : appName,
      ` · ${build.workflow} · `,
      h('span', { class: 'mono' }, build.ref),
      ' ',
      h('span', { class: 'mono secondary', title: build.commit }, `(${shortSHA(build.commit)})`)),
    leading: app ? appIcon(app, 'large') : null,
    actions,
  },
  meta,
  section({ title: build.jobs.length === 1 ? 'Job' : 'Jobs' }, jobsElement),
  section({ title: 'Log' }, log.element));
  view.dataset.documentTitle = `Build ${build.buildNumber} · ${appName}`;
  view.prepend(h('a', { href: '/builds', 'data-link': true, class: 'back-link' }, h('span', { 'aria-hidden': 'true' }, '‹ '), 'History'));
  return view;
}

// MARK: Job card

function jobCardView(initial, { machines, live, signal }) {
  const element = card({ class: 'job-card' });
  const head = h('div', { class: 'job-head' });
  const body = h('div', { class: 'job-body' });
  const artifacts = h('div', { class: 'job-artifacts' });
  element.append(head, body, artifacts);
  let job = initial;
  let artifactsLoaded = false;
  let artifactsGeneration = 0;

  async function loadArtifacts() {
    const generation = ++artifactsGeneration;
    artifactsLoaded = true;
    replaceChildren(artifacts, h('h3', { class: 'job-subtitle' }, 'Artifacts'), spinner('Loading artifacts'));
    let list;
    try {
      list = await api.get(`/jobs/${seg(job.id)}/artifacts`, { signal });
    } catch (error) {
      if (error.code === 'aborted' || generation !== artifactsGeneration) return;
      replaceChildren(artifacts,
        h('h3', { class: 'job-subtitle' }, 'Artifacts'),
        h('p', { class: 'inline-error-message' }, error.message),
        button('Try Again', { kind: 'plain', class: 'button button-plain button-small', onClick: loadArtifacts }));
      return;
    }
    if (generation !== artifactsGeneration) return;
    if (list.length === 0) {
      replaceChildren(artifacts, isTerminal(job.status)
        ? [h('h3', { class: 'job-subtitle' }, 'Artifacts'), h('p', { class: 'card-detail' }, 'This job kept no artifacts.')]
        : null);
      return;
    }
    replaceChildren(artifacts,
      h('h3', { class: 'job-subtitle' }, 'Artifacts'),
      h('ul', { class: 'artifact-list' }, list.map((artifact) => h('li', null,
        h('a', {
          class: 'artifact-link',
          href: `/api/v1/jobs/${seg(job.id)}/artifacts/${seg(artifact.name)}`,
          download: artifact.name,
        },
        h('span', { class: 'artifact-name' }, artifact.name),
        h('span', { class: 'artifact-size' }, formatBytes(artifact.sizeBytes)))))));
  }

  function update(next) {
    const becameTerminal = isTerminal(next.status) && !isTerminal(job.status);
    job = next;
    const machine = job.machineID ? machines.get(job.machineID) : null;
    replaceChildren(head,
      h('div', { class: 'job-title-block' },
        h('h3', { class: 'job-title' }, actionLabel(job.action)),
        h('p', { class: 'card-detail' },
          machine ? machine.name : job.machineID ? 'Unknown machine' : 'No machine yet',
          job.startedAt
            ? [' · ', live(h('span', null), () => duration(job.startedAt, isTerminal(job.status) ? (job.finishedAt ?? job.startedAt) : null))]
            : null)),
      statusBadge(job.status));

    // A test job's `test.*` outputs are shown as its Tests section instead.
    const outputs = Object.entries(job.outputs ?? {})
      .filter(([key]) => !key.startsWith('test.'))
      .sort(([a], [b]) => a.localeCompare(b));
    replaceChildren(body,
      job.status === 'queued' && job.queueNote ? h('p', { class: 'queue-note' }, job.queueNote) : null,
      job.steps?.length
        ? h('ol', { class: 'steps', 'aria-label': 'Steps' }, job.steps.map((step) => stepRow(step, job, live)))
        : h('p', { class: 'card-detail' }, isTerminal(job.status) ? 'No steps ran.' : 'Steps appear once a machine starts the job.'),
      job.failureReason ? h('p', { class: 'failure-reason', role: 'note' }, job.failureReason) : null,
      testsView(job),
      outputs.length
        ? h('dl', { class: 'facts job-outputs' }, outputs.map(([key, value]) => h('div', { class: 'fact' },
          h('dt', { class: 'fact-label' }, OUTPUT_LABELS[key] ?? key),
          h('dd', { class: 'fact-value mono' }, value))))
        : null);

    // Artifacts arrive while a job runs and are complete once it ends.
    if (becameTerminal || (!artifactsLoaded && job.status !== 'queued' && job.status !== 'assigned')) loadArtifacts();
  }

  return { element, update };
}

function stepRow(step, job, live) {
  const time = h('span', { class: 'step-duration' });
  if (step.startedAt && step.finishedAt) time.textContent = duration(step.startedAt, step.finishedAt);
  // A step left running by a job that ended (a lost worker, say) stops at the job's end instead of ticking on.
  else if (step.startedAt && isTerminal(job.status)) time.textContent = duration(step.startedAt, job.finishedAt ?? step.startedAt);
  else if (step.startedAt) live(time, () => duration(step.startedAt));
  return h('li', { class: ['step', `step-row-${step.status}`] },
    stepIcon(step.status),
    h('span', { class: 'step-name' }, stepLabel(step.name)),
    h('span', { class: 'visually-hidden' }, `, ${step.status}`),
    time);
}

// MARK: Log panel

function logPanel(initialJobs, context) {
  let jobs = initialJobs;
  let selectedJob = jobs[0]?.id ?? null;
  let selectedStep = '';
  let stop = null;
  let pinned = true;
  let lineCount = 0;
  let stepOptions = null; // the step names the filter lists, joined

  const tabs = h('div', { class: 'segmented log-tabs', role: 'tablist', 'aria-label': 'Job' });
  const stepSelect = h('select', {
    class: 'input select log-step-select', 'aria-label': 'Step',
    onChange: () => {
      selectedStep = stepSelect.value;
      restart();
    },
  });
  const lines = h('div', {
    class: 'log-lines', role: 'log', 'aria-live': 'off', tabindex: '0', 'aria-label': 'Log',
  });
  const status = h('p', { class: 'log-status' });
  const jump = h('button', {
    type: 'button', class: 'button button-primary button-small log-jump', hidden: true,
    onClick: () => {
      pinned = true;
      jump.hidden = true;
      lines.scrollTop = lines.scrollHeight;
    },
  }, 'Jump to latest');
  lines.addEventListener('scroll', () => {
    pinned = lines.scrollTop + lines.clientHeight >= lines.scrollHeight - 24;
    if (pinned) jump.hidden = true;
  });

  const element = h('div', { class: 'log-panel' },
    h('div', { class: 'log-toolbar' }, tabs, stepSelect),
    h('div', { class: 'log-viewport' }, lines, jump),
    status);

  function renderTabs() {
    if (jobs.length < 2) {
      tabs.hidden = true;
      return;
    }
    tabs.hidden = false;
    replaceChildren(tabs, jobs.map((job, index) => h('button', {
      type: 'button', class: 'segment', role: 'tab', 'aria-selected': String(job.id === selectedJob),
      tabindex: job.id === selectedJob ? '0' : '-1',
      onClick: () => select(job.id),
      onKeydown: (event) => {
        if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
        event.preventDefault();
        const next = jobs[(index + (event.key === 'ArrowRight' ? 1 : jobs.length - 1)) % jobs.length];
        select(next.id);
        tabs.querySelector('[aria-selected="true"]')?.focus();
      },
    }, actionLabel(job.action))));
  }

  function renderSteps() {
    const job = jobs.find((candidate) => candidate.id === selectedJob);
    const names = (job?.steps ?? []).map((step) => step.name);
    stepOptions = names.join();
    if (selectedStep && !names.includes(selectedStep)) names.push(selectedStep);
    replaceChildren(stepSelect,
      h('option', { value: '' }, 'All steps'),
      names.map((name) => h('option', { value: name }, stepLabel(name))));
    stepSelect.value = selectedStep;
  }

  function select(jobID) {
    if (jobID === selectedJob) return;
    selectedJob = jobID;
    selectedStep = '';
    renderTabs();
    renderSteps();
    restart();
  }

  function append(entries) {
    if (lineCount === 0) status.textContent = '';
    const fresh = entries.length > LOG_LINE_CAP ? entries.slice(-LOG_LINE_CAP) : entries;
    const fragment = document.createDocumentFragment();
    for (const entry of fresh) {
      const line = document.createElement('div');
      line.className = 'log-line';
      line.textContent = `${logTime(entry.t)} [${entry.step}] ${entry.line}`;
      fragment.append(line);
    }
    lines.append(fragment);
    lineCount += fresh.length;
    while (lineCount > LOG_LINE_CAP) {
      lines.firstChild.remove();
      lineCount -= 1;
    }
    if (pinned) lines.scrollTop = lines.scrollHeight;
    else jump.hidden = false;
  }

  function restart() {
    stop?.();
    stop = null;
    // Never open a stream for a page that is gone (its cleanups have already run).
    if (context.signal.aborted) return;
    lines.replaceChildren();
    lineCount = 0;
    pinned = true;
    jump.hidden = true;
    if (!selectedJob) {
      status.textContent = 'This build has no jobs.';
      return;
    }
    const job = jobs.find((candidate) => candidate.id === selectedJob);
    status.textContent = job && isTerminal(job.status) ? 'Loading the log…' : 'Waiting for output…';
    const jobID = selectedJob;
    stop = followLog(jobID, selectedStep || null, append, () => {
      if (jobID !== selectedJob) return;
      status.textContent = lineCount === 0 ? 'The job wrote no log.' : 'The job has finished.';
    }, (error) => {
      if (jobID !== selectedJob) return;
      status.replaceChildren(
        h('span', { class: 'inline-error-message' }, `The log could not be loaded: ${error.message} `),
        button('Try Again', { kind: 'plain', class: 'button button-plain button-small', onClick: restart }));
    });
  }

  context.onCleanup(() => stop?.());

  renderTabs();
  renderSteps();
  restart();

  return {
    element,
    /** Keeps the step filter in step with the selected job's steps (a build's jobs never change). */
    updateJobs(next) {
      jobs = next;
      const names = (jobs.find((job) => job.id === selectedJob)?.steps ?? []).map((step) => step.name).join();
      if (names !== stepOptions) renderSteps();
    },
  };
}

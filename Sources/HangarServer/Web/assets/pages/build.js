// The build detail page (`/builds/:id`): the build's header, one card per job with its steps, outputs and
// artifacts, and the log, all kept live from the event and log streams.

import { api, ApiError, events, followLog, seg } from '../api.js';
import {
  button, card, confirm, duration, emptyState, h, page, relativeTime, replaceChildren, section, spinner, statusBadge,
  svg, toast,
} from '../ui.js';
import { jobRunLine, stepDetail, stepDisplayStatus, stepStages, stepStatusWords } from '../build-model.js';
import {
  appendEntries, countLabel, createLog, defaultOpenSteps, displayText, issuePositions, issueTotals, lineSegments, visibleLines,
} from '../log-model.js';
import { appIcon } from './apps.js';
import { platformName } from '../workflow-summary.js';

const FULL_LOG = 'full-log.txt';
const TERMINAL = new Set(['succeeded', 'failed', 'cancelled']);

const STEP_LABELS = {
  checkout: 'Check out',
  'post-clone': 'Post-clone script',
  'pre-xcodebuild': 'Pre-xcodebuild script',
  archive: 'Archive',
  test: 'Test',
  stamp: 'Stamp build number',
  export: 'Export',
  notarize: 'Notarize',
  'post-xcodebuild': 'Post-xcodebuild script',
  'upload-artifacts': 'Upload artifacts',
  cleanup: 'Clean up',
  'post-action:testflight': 'TestFlight',
};

const OUTPUT_LABELS = {
  'testflight.processingState': 'TestFlight build state',
  'testflight.buildID': 'TestFlight build ID',
  'notarization.submissionID': 'Notarization submission',
  'notarization.status': 'Notarization status',
};

// MARK: Shared helpers

/** "Archive – iOS · LegiloMobile" or "Test – iOS · LegiloTests" for a `WorkflowAction`. */
export function actionLabel(action) {
  const kind = action?.kind === 'test' ? 'Test' : 'Archive';
  return `${kind} – ${platformName(action?.platform)} · ${action?.scheme ?? '?'}`;
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
    warning: [['path', { d: 'M12 7v6' }], ['path', { d: 'M12 16.5v.5' }]],
    cancelled: [['path', { d: 'M8 8l8 8' }]],
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
    // What was built (the .ipa, .pkg, app or disk image) first and marked; dSYMs, results and plists after it.
    const products = list.filter((artifact) => isProduct(artifact.name));
    const others = list.filter((artifact) => !isProduct(artifact.name));
    const row = (artifact, product) => h('li', null,
      h('a', {
        class: ['artifact-link', product && 'artifact-product'],
        href: `/api/v1/jobs/${seg(job.id)}/artifacts/${seg(artifact.name)}`,
        download: artifact.name,
      },
      product ? downloadGlyph() : null,
      h('span', { class: 'artifact-name' }, artifact.name),
      h('span', { class: 'artifact-size' }, formatBytes(artifact.sizeBytes))));
    replaceChildren(artifacts,
      h('h3', { class: 'job-subtitle' }, 'Artifacts'),
      products.length ? h('ul', { class: 'artifact-list' }, products.map((artifact) => row(artifact, true))) : null,
      others.length && products.length ? h('h4', { class: 'artifact-others' }, 'Other Files') : null,
      others.length ? h('ul', { class: 'artifact-list' }, others.map((artifact) => row(artifact, false))) : null);
  }

  function update(next) {
    const becameTerminal = isTerminal(next.status) && !isTerminal(job.status);
    job = next;
    const machine = job.machineID ? machines.get(job.machineID) : null;
    replaceChildren(head,
      h('div', { class: 'job-title-block' },
        h('h3', { class: 'job-title' }, actionLabel(job.action)),
        h('p', { class: 'card-detail' },
          jobRunLine(job, machine),
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
  const status = stepDisplayStatus(step, job);
  const time = h('span', { class: 'step-duration' });
  if (step.startedAt && step.finishedAt) time.textContent = duration(step.startedAt, step.finishedAt);
  // A step left running by a job that ended (a lost worker, say) stops at the job's end instead of ticking on.
  else if (step.startedAt && isTerminal(job.status)) time.textContent = duration(step.startedAt, job.finishedAt ?? step.startedAt);
  else if (step.startedAt) live(time, () => duration(step.startedAt));
  const detail = stepDetail(step, job);
  const stages = stepStages(step, job);
  return h('li', { class: ['step', `step-row-${status}`] },
    stepIcon(status),
    h('span', { class: 'step-name' }, stepLabel(step.name)),
    h('span', { class: 'visually-hidden' }, `, ${stepStatusWords(status)}`),
    time,
    detail ? h('p', { class: ['step-detail', `step-detail-${status}`] }, detail) : null,
    stages.length
      ? h('ol', { class: 'step-stages', 'aria-label': `${stepLabel(step.name)} stages` }, stages.map((stage) => h('li', {
        class: ['step-stage', `step-row-${stage.status}`],
      },
      stepIcon(stage.status),
      h('span', { class: 'step-stage-name' }, stage.name),
      h('span', { class: 'visually-hidden' }, `, ${stepStatusWords(stage.status)}`),
      stage.detail ? h('span', { class: 'step-stage-detail' }, stage.detail) : null)))
      : null);
}

// MARK: Log panel

/** Lines a step renders at most; the rest are in the downloadable log. */
const RENDER_LIMIT = 4000;

/**
 * The log of one job at a time: a section per step (the failed step open, the running one while the job runs,
 * the others closed), errors and warnings counted with links that jump to each in turn, a filter for just those,
 * a search, and a link to download the log. Follows new lines while scrolled to the bottom.
 */
function logPanel(initialJobs, context) {
  let jobs = initialJobs;
  let selectedJob = jobs[0]?.id ?? null;
  let stop = null;
  let pinned = true;
  let model = createLog();
  let issuesOnly = false;
  let query = '';
  /** Per step: its section's elements and how many of its lines are rendered. */
  let sections = new Map();
  /** Steps the reader opened or closed; their choice stands over the defaults. */
  let userChoice = new Map();
  /** Steps whose next `toggle` event comes from this code, not the reader. */
  const programmatic = new Set();
  const cursor = { error: -1, warning: -1 };
  let downloadGeneration = 0;

  const tabs = h('div', { class: 'segmented log-tabs', role: 'tablist', 'aria-label': 'Job' });
  const filterAll = h('button', { type: 'button', class: 'segment', role: 'radio', 'aria-checked': 'true', onClick: () => setIssuesOnly(false) }, 'All');
  const filterIssues = h('button', { type: 'button', class: 'segment', role: 'radio', 'aria-checked': 'false', onClick: () => setIssuesOnly(true) }, 'Errors & Warnings');
  const filter = h('div', { class: 'segmented log-filter', role: 'radiogroup', 'aria-label': 'Show' }, filterAll, filterIssues);
  let searchTimer = null;
  const search = h('input', {
    type: 'search', class: 'input log-search', placeholder: 'Search the log', 'aria-label': 'Search the log',
    autocomplete: 'off', spellcheck: 'false',
    onInput: () => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => {
        query = search.value;
        refilter();
      }, 150);
    },
  });
  const errorsLink = h('button', { type: 'button', class: 'log-count log-count-error', hidden: true, onClick: () => jump('error') });
  const warningsLink = h('button', { type: 'button', class: 'log-count log-count-warning', hidden: true, onClick: () => jump('warning') });
  const download = h('a', { class: 'log-download', hidden: true });
  const announcer = h('p', { class: 'visually-hidden', 'aria-live': 'polite' });
  const lines = h('div', {
    class: 'log-lines', role: 'log', 'aria-live': 'off', tabindex: '0', 'aria-label': 'Log',
  });
  const status = h('p', { class: 'log-status' });
  const jumpLatest = h('button', {
    type: 'button', class: 'button button-primary button-small log-jump', hidden: true,
    onClick: () => {
      pinned = true;
      jumpLatest.hidden = true;
      lines.scrollTop = lines.scrollHeight;
    },
  }, 'Jump to latest');
  lines.addEventListener('scroll', () => {
    pinned = lines.scrollTop + lines.clientHeight >= lines.scrollHeight - 24;
    if (pinned) jumpLatest.hidden = true;
  });

  const element = h('div', { class: 'log-panel' },
    h('div', { class: 'log-toolbar' }, tabs, filter, search),
    h('div', { class: 'log-summary' }, errorsLink, warningsLink, download, announcer),
    h('div', { class: 'log-viewport' }, lines, jumpLatest),
    status);

  function selectedJobValue() {
    return jobs.find((candidate) => candidate.id === selectedJob);
  }

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

  function select(jobID) {
    if (jobID === selectedJob) return;
    selectedJob = jobID;
    renderTabs();
    restart();
  }

  // MARK: Filter and search

  function filtering() {
    return issuesOnly || query.trim() !== '';
  }

  function setIssuesOnly(value) {
    if (issuesOnly === value) return;
    issuesOnly = value;
    filterAll.setAttribute('aria-checked', String(!value));
    filterIssues.setAttribute('aria-checked', String(value));
    refilter();
  }

  function refilter() {
    for (const step of model.steps) renderSection(step.name, { rebuild: true });
    applyOpenState();
    updateStatusLine();
    if (pinned) lines.scrollTop = lines.scrollHeight;
  }

  // MARK: Sections

  function stepStatus(name) {
    const job = selectedJobValue();
    const step = job?.steps?.find((candidate) => candidate.name === name);
    return step ? stepDisplayStatus(step, job) : 'pending';
  }

  function section(name) {
    let entry = sections.get(name);
    if (entry) return entry;
    const counts = h('span', { class: 'log-step-counts' });
    const summary = h('summary', { class: 'log-step-summary' });
    const body = h('div', { class: 'log-step-body' });
    const details = h('details', { class: 'log-step', dataset: { step: name } }, summary, body);
    details.addEventListener('toggle', () => {
      if (programmatic.delete(name)) return;
      if (!filtering()) userChoice.set(name, details.open);
      if (details.open) renderSection(name, { rebuild: true });
    });
    entry = { details, summary, body, counts, rendered: 0, signature: '' };
    sections.set(name, entry);
    // Steps appear in the order their first line arrived.
    lines.append(details);
    return entry;
  }

  function renderSummary(name) {
    const entry = section(name);
    const step = model.byName[name];
    const status = stepStatus(name);
    const shown = filtering() ? visibleLines(step, { issuesOnly, query }).filter((line) => line.kind !== 'task').length : null;
    const signature = [status, step.errors, step.warnings, step.lines.length, shown].join('|');
    if (signature === entry.signature) return;
    entry.signature = signature;
    replaceChildren(entry.counts,
      step.errors ? h('span', { class: 'log-badge log-badge-error' }, countLabel(step.errors, 'error')) : null,
      step.warnings ? h('span', { class: 'log-badge log-badge-warning' }, countLabel(step.warnings, 'warning')) : null,
      h('span', { class: 'log-step-lines' }, shown === null
        ? countLabel(step.lines.length + step.dropped, 'line')
        : `${shown} of ${step.lines.length + step.dropped}`));
    replaceChildren(entry.summary,
      stepIcon(status),
      h('span', { class: 'log-step-name' }, stepLabel(name)),
      h('span', { class: 'visually-hidden' }, `, ${stepStatusWords(status)}`),
      entry.counts);
  }

  /** Renders the step's lines when its section is open: all again with `rebuild`, else just the new ones. */
  function renderSection(name, { rebuild = false } = {}) {
    const entry = section(name);
    const step = model.byName[name];
    renderSummary(name);
    if (!entry.details.open) {
      if (rebuild) {
        entry.body.replaceChildren();
        entry.rendered = 0;
      }
      return;
    }
    if (filtering() || rebuild || entry.rendered === 0) {
      const visible = filtering() ? visibleLines(step, { issuesOnly, query }) : step.lines;
      const shown = visible.length > RENDER_LIMIT ? visible.slice(-RENDER_LIMIT) : visible;
      const hidden = visible.length - shown.length + (filtering() ? 0 : step.dropped);
      const fragment = document.createDocumentFragment();
      if (hidden > 0) {
        fragment.append(h('div', { class: 'log-line log-line-note' },
          `${countLabel(hidden, 'earlier line')} not shown here; download the log to see everything.`));
      }
      if (filtering() && visible.length === 0) {
        fragment.append(h('div', { class: 'log-line log-line-note' }, issuesOnly && !query.trim()
          ? 'No errors or warnings in this step.'
          : 'No lines match.'));
      }
      for (const line of shown) fragment.append(lineView(line));
      entry.body.replaceChildren(fragment);
      entry.rendered = step.lines.length ? step.lines[step.lines.length - 1].index + 1 : 0;
      return;
    }
    // Unfiltered and open: append what arrived since the last render.
    const fresh = step.lines.filter((line) => line.index >= entry.rendered);
    if (!fresh.length) return;
    const fragment = document.createDocumentFragment();
    for (const line of fresh) fragment.append(lineView(line));
    entry.body.append(fragment);
    entry.rendered = fresh[fresh.length - 1].index + 1;
    while (entry.body.childElementCount > RENDER_LIMIT) entry.body.firstElementChild.remove();
  }

  function lineView(line) {
    const text = h('span', { class: 'log-text' });
    for (const segment of lineSegments(line.text, query)) {
      const piece = segment.mark ? h('mark', { class: 'log-mark' }, segment.text) : document.createTextNode(segment.text);
      text.append(segment.title
        ? h('span', { class: 'log-path', title: segment.title }, piece)
        : piece);
    }
    return h('div', { class: ['log-line', `log-${line.kind}`], dataset: { line: String(line.index) } },
      h('span', { class: 'log-time', 'aria-hidden': 'true' }, logTime(line.t)),
      text);
  }

  function setOpen(name, open) {
    const entry = section(name);
    if (entry.details.open === open) return;
    programmatic.add(name);
    entry.details.open = open;
    if (open) renderSection(name, { rebuild: true });
  }

  /** Opens and closes sections: while filtering, those with matches; otherwise the reader's choice or the default. */
  function applyOpenState() {
    const defaults = new Set(defaultOpenSteps(model, selectedJobValue()));
    for (const step of model.steps) {
      if (filtering()) {
        setOpen(step.name, visibleLines(step, { issuesOnly, query }).length > 0);
      } else {
        setOpen(step.name, userChoice.has(step.name) ? userChoice.get(step.name) : defaults.has(step.name));
      }
    }
  }

  // MARK: Counts and jumps

  function updateStatusLine() {
    const totals = issueTotals(model);
    errorsLink.hidden = totals.errors === 0;
    warningsLink.hidden = totals.warnings === 0;
    errorsLink.textContent = countLabel(totals.errors, 'error');
    warningsLink.textContent = countLabel(totals.warnings, 'warning');
    errorsLink.title = 'Jump to the next error';
    warningsLink.title = 'Jump to the next warning';
  }

  /** Scrolls to the next error or warning (after the last one jumped to), opening its step. */
  function jump(kind) {
    const positions = issuePositions(model, kind);
    if (!positions.length) return;
    cursor[kind] = (cursor[kind] + 1) % positions.length;
    const target = positions[cursor[kind]];
    if (query.trim()) {
      search.value = '';
      query = '';
      refilter();
    }
    if (!filtering()) userChoice.set(target.step, true);
    setOpen(target.step, true);
    const row = section(target.step).body.querySelector(`[data-line="${target.index}"]`);
    if (!row) return;
    pinned = false;
    jumpLatest.hidden = false;
    // Within the log box only: scrollIntoView would move the whole page too.
    lines.scrollTop += row.getBoundingClientRect().top - lines.getBoundingClientRect().top - lines.clientHeight / 3;
    row.classList.remove('log-line-flash');
    void row.offsetWidth;
    row.classList.add('log-line-flash');
    const words = kind === 'error' ? 'Error' : 'Warning';
    announcer.textContent = `${words} ${cursor[kind] + 1} of ${positions.length}: ${displayText(row.querySelector('.log-text')?.textContent ?? '')}`;
  }

  // MARK: Download

  /** Links the full log once the job kept one, else the log as stored. */
  async function updateDownload() {
    const job = selectedJobValue();
    if (!job) {
      download.hidden = true;
      return;
    }
    const generation = ++downloadGeneration;
    const stored = () => {
      download.href = `/api/v1/jobs/${seg(job.id)}/log?format=text`;
      download.download = `log-${job.id.toLowerCase()}.txt`;
      download.textContent = 'Download log';
      download.title = 'The log as shown here, as a text file';
      download.hidden = false;
    };
    stored();
    if (!isTerminal(job.status)) return;
    try {
      const artifacts = await api.get(`/jobs/${seg(job.id)}/artifacts`, { signal: context.signal });
      if (generation !== downloadGeneration || !artifacts.some((artifact) => artifact.name === FULL_LOG)) return;
      download.href = `/api/v1/jobs/${seg(job.id)}/artifacts/${FULL_LOG}`;
      download.download = FULL_LOG;
      download.textContent = 'Download full log';
      download.title = 'Everything xcodebuild printed, compiler invocations included';
    } catch {
      // The stored log stays linked.
    }
  }

  // MARK: Stream

  function append(entries) {
    if (model.steps.length === 0) status.textContent = '';
    const changed = appendEntries(model, entries);
    const known = new Set(sections.keys());
    for (const name of changed) {
      section(name);
      if (!known.has(name)) applyOpenStateFor(name);
      renderSection(name);
    }
    updateStatusLine();
    if (pinned) lines.scrollTop = lines.scrollHeight;
    else jumpLatest.hidden = false;
  }

  /** The open state of a step that just appeared. */
  function applyOpenStateFor(name) {
    const step = model.byName[name];
    if (filtering()) setOpen(name, visibleLines(step, { issuesOnly, query }).length > 0);
    else setOpen(name, userChoice.get(name) ?? defaultOpenSteps(model, selectedJobValue()).includes(name));
  }

  function restart() {
    stop?.();
    stop = null;
    // Never open a stream for a page that is gone (its cleanups have already run).
    if (context.signal.aborted) return;
    lines.replaceChildren();
    model = createLog();
    sections = new Map();
    userChoice = new Map();
    programmatic.clear();
    cursor.error = -1;
    cursor.warning = -1;
    announcer.textContent = '';
    pinned = true;
    jumpLatest.hidden = true;
    updateStatusLine();
    updateDownload();
    if (!selectedJob) {
      status.textContent = 'This build has no jobs.';
      return;
    }
    const job = selectedJobValue();
    status.textContent = job && isTerminal(job.status) ? 'Loading the log…' : 'Waiting for output…';
    const jobID = selectedJob;
    stop = followLog(jobID, null, append, () => {
      if (jobID !== selectedJob) return;
      status.textContent = model.steps.length === 0 ? 'The job wrote no log.' : '';
    }, (error) => {
      if (jobID !== selectedJob) return;
      status.replaceChildren(
        h('span', { class: 'inline-error-message' }, `The log could not be loaded: ${error.message} `),
        button('Try Again', { kind: 'plain', class: 'button button-plain button-small', onClick: restart }));
    });
  }

  context.onCleanup(() => {
    stop?.();
    clearTimeout(searchTimer);
  });

  renderTabs();
  restart();

  return {
    element,
    /** Keeps step icons and open sections in step with the jobs (a build's jobs never change). */
    updateJobs(next) {
      const before = selectedJobValue();
      jobs = next;
      const after = selectedJobValue();
      for (const step of model.steps) renderSummary(step.name);
      if (!filtering()) applyOpenState();
      if (after && before && isTerminal(after.status) && !isTerminal(before.status)) updateDownload();
    },
  };
}

/** An artifact that is the build's product rather than a by-product: an installable or shareable app. */
function isProduct(name) {
  return /\.(ipa|pkg|dmg)$/i.test(name) || /\.app(\.zip)?$/i.test(name);
}

/** An arrow into a tray, before a product's name. */
function downloadGlyph() {
  return svg('svg', { class: 'artifact-icon', viewBox: '0 0 24 24', 'aria-hidden': 'true', focusable: 'false' },
    svg('path', { d: 'M12 4v11M7.5 10.5 12 15l4.5-4.5M5 19h14' }));
}

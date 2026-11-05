// The app detail page, in the order a visit needs it: what (if anything) keeps builds from running, the latest
// build and what the workflow does, recent builds, then the rarer things: build numbers, environment and removal.

import { api, ApiError, events, seg } from '../api.js';
import { navigate } from '../router.js';
import {
  button, card, emptyState, field, h, page, relativeTime, replaceChildren, section, sheet, spinner, statusBadge,
  toast,
} from '../ui.js';
import { appIcon, recheckIconSoon } from './apps.js';
import { buildDuration } from './build.js';
import { buildRow } from './build-rows.js';
import { openDeploySheet } from './deploy.js';
import { variablesEditor } from './variables.js';
import { toWorkflow } from '../workflow-model.js';
import { workflowToYAML } from '../yaml.js';
import { workflowSummary } from '../workflow-summary.js';
import { betaGroupsStore, branchesStore } from './workflow-parts.js';
import { openWorkflowWizard } from './workflow-wizard.js';

const RECENT_BUILDS = 20;

/** The `/apps/:app` route. */
export async function appDetailPage(params, context) {
  const { signal } = context;
  let app;
  try {
    app = await api.get(`/apps/${seg(params.app)}`, { signal });
  } catch (error) {
    if (error instanceof ApiError && error.code === 'app_not_found') {
      return page({ title: 'App Not Found' }, emptyState({
        title: `There is no app “${params.app}”`,
        message: 'It may have been removed.',
        action: h('a', { href: '/', 'data-link': true, class: 'button button-primary' }, 'Go to Apps'),
      }));
    }
    throw error;
  }
  const slug = seg(app.slug);

  const notice = machinesNotice(signal);
  const latest = latestCard();
  const workflow = workflowCard(app, signal);
  const builds = buildsList(app, signal, (list) => latest.render(list[0] ?? null));
  const numbers = numbersCard(app, signal);

  context.onCleanup(events((event) => {
    if (event.type === 'build' && event.build?.appID === app.id) builds.upsert(event.build);
    if (event.type === 'machine') notice.seen(event.machine);
  }, { onReconnect: () => { builds.reload(); notice.reload(); } }));
  const timer = setInterval(() => { builds.tick(); latest.tick(); }, 60_000);
  context.onCleanup(() => clearInterval(timer));

  let icon = appIcon(app, 'large');
  recheckIconSoon([app], context, async () => {
    const updated = await api.get(`/apps/${slug}`, { signal });
    if (!updated.iconURL || !icon.isConnected) return;
    const next = appIcon(updated, 'large');
    icon.replaceWith(next);
    icon = next;
  });

  const element = page({
    title: app.name,
    subtitle: /^https:\/\//i.test(app.repoURL)
      ? h('a', { href: app.repoURL, target: '_blank', rel: 'noopener noreferrer' }, app.repoURL.replace(/^https:\/\//i, ''))
      : app.repoURL,
    leading: icon,
    actions: button('Deploy', { kind: 'primary', onClick: () => openDeploySheet(app) }),
  },
  notice.element,
  h('div', { class: 'detail-grid' }, latest.element, workflow),
  section({ title: 'Recent Builds', actions: h('a', { href: `/builds?app=${slug}`, 'data-link': true, class: 'section-link' }, 'All Builds') },
    builds.element),
  section({ title: 'Build Numbers' }, numbers),
  section({
    title: 'Environment',
    footer: 'Every job of this app gets these variables. One with the same name as a global variable replaces it.',
  }, variablesEditor({ scope: { app: app.slug }, signal })),
  section({ title: 'Remove App' }, removeCard(app)));
  element.prepend(h('a', { href: '/', 'data-link': true, class: 'back-link' }, h('span', { 'aria-hidden': 'true' }, '‹ '), 'Apps'));
  return element;
}

// MARK: Machines

/**
 * A notice above everything while there is no Mac to build on, with the way to add one. Whether a Mac is online
 * and able is the Deploy sheet's question to the server; this only counts machines, so it needs no clock.
 */
function machinesNotice(signal) {
  const element = h('div', { class: 'page-notice-slot' });
  let known = null; // ids of the machines listed
  async function reload() {
    let machines;
    try {
      machines = await api.get('/machines', { signal });
    } catch {
      return; // Not worth a warning of its own; the Deploy sheet says it again.
    }
    known = new Set(machines.map((machine) => machine.id));
    replaceChildren(element, machines.length === 0
      ? h('div', { class: 'page-notice', role: 'note' },
        h('p', null, 'No Mac can run builds yet. Add one and Deploy can start.'),
        h('a', { href: '/machines?add=1', 'data-link': true, class: 'button button-secondary button-small' }, 'Add a Mac'))
      : null);
  }
  /** A heartbeat of a machine already listed changes nothing here; a new one is worth a fresh list. */
  function seen(machine) {
    if (known && machine && !known.has(machine.id)) reload();
  }
  reload();
  return { element, reload, seen };
}

// MARK: Latest build

function latestCard() {
  const element = card({ class: 'latest-card' });
  let build;
  let when = null;

  function tick() {
    if (when && build) when.textContent = `${relativeTime(build.createdAt)} · ${buildDuration(build)}`;
  }

  function render(next) {
    build = next;
    if (build === null) {
      when = null;
      replaceChildren(element,
        cardTitle('Latest Build'),
        h('p', { class: 'card-headline' }, 'No builds yet'),
        h('p', { class: 'card-detail' }, 'Deploy runs the workflow; its build and files show up here.'));
      return;
    }
    when = h('span', null);
    replaceChildren(element,
      cardTitle('Latest Build', statusBadge(build.status)),
      h('a', { href: `/builds/${seg(build.id)}`, 'data-link': true, class: 'latest-link' },
        h('span', { class: 'latest-number' }, `Build ${build.buildNumber}`),
        h('span', { class: 'card-detail latest-ref' }, `${build.workflow} · ${build.ref} · ${String(build.commit ?? '').slice(0, 7)}`)),
      h('p', { class: 'card-note' }, when),
      h('div', { class: 'card-actions' },
        h('a', { href: `/builds/${seg(build.id)}`, 'data-link': true, class: 'button button-secondary' }, 'View Build')));
    tick();
  }

  replaceChildren(element, cardTitle('Latest Build'), h('div', { class: 'card-loading' }, spinner('Loading the latest build')));
  return { element, render, tick };
}

/** A card's heading row: the title and an optional trailing control. */
function cardTitle(text, trailing) {
  return h('div', { class: 'card-title-row' }, h('h2', { class: 'card-title' }, text), trailing);
}

// MARK: Build numbers

function numbersCard(app, signal) {
  const element = card({ class: 'numbers-card' });
  const path = `/apps/${seg(app.slug)}/numbers`;

  function loading() {
    replaceChildren(element, h('div', { class: 'card-loading' }, spinner('Loading numbers')));
  }

  async function load() {
    loading();
    try {
      render(await api.get(path, { signal }));
    } catch (error) {
      if (error.code === 'aborted') return;
      renderError(error);
    }
  }

  function render(report) {
    const fact = (label, value) => h('div', { class: 'fact' },
      h('dt', { class: 'fact-label' }, label),
      h('dd', { class: 'fact-value' }, value ?? '–'));
    replaceChildren(element,
      h('div', { class: 'card-title-row' },
        h('p', { class: 'card-headline' }, 'Next build gets ', h('span', { class: 'numbers-next' }, String(report.next))),
        button('Raise…', { kind: 'plain', class: 'button button-plain button-small', onClick: () => raise(report) })),
      h('dl', { class: 'facts' },
        fact('Highest in Hangar', report.highestHangar),
        fact('Highest in App Store Connect', report.highestAppStoreConnect),
        // Only Xcode Cloud migrants have one; a dash would be noise for everyone else.
        report.lastXcodeCloudRun != null ? fact('Last Xcode Cloud run', report.lastXcodeCloudRun) : null),
      report.inFlight
        ? h('p', { class: 'card-note' }, 'A build is in progress and has already taken its number.')
        : null);
  }

  function renderError(error) {
    const needsKey = error.code === 'app_store_connect_not_configured';
    replaceChildren(element,
      h('p', { class: 'inline-error-message' }, error.message),
      h('div', { class: 'card-actions' },
        needsKey
          ? h('a', { href: '/settings', 'data-link': true, class: 'button button-secondary' }, 'Open Settings')
          : null,
        button('Try Again', { kind: 'plain', onClick: load })));
  }

  function raise(report) {
    const input = h('input', {
      class: 'input mono', type: 'text', inputmode: 'numeric', autocomplete: 'off', spellcheck: 'false',
      placeholder: String(report.next + 1), autofocus: true,
      onInput: () => input.removeAttribute('aria-invalid'),
    });
    sheet({
      title: 'Raise Next Build Number',
      submitOnEnter: true,
      body: h('div', { class: 'form' },
        h('p', { class: 'sheet-message' },
          `The next build would get ${report.next}. Hangar never lowers the number, so pick a higher one.`),
        field({ label: 'Next build number', control: input })),
      actions: [
        { label: 'Cancel', kind: 'cancel' },
        {
          label: 'Raise',
          kind: 'primary',
          onClick: async () => {
            const text = input.value.trim();
            const next = /^\d+$/.test(text) ? Number(text) : NaN;
            const fail = (message) => {
              input.setAttribute('aria-invalid', 'true');
              input.focus();
              throw new Error(message);
            };
            if (!Number.isSafeInteger(next)) fail('Enter a whole number.');
            if (next <= report.next) fail(`Must be higher than ${report.next}.`);
            try {
              render(await api.put(`/apps/${seg(app.slug)}/numbers/next`, { next }));
            } catch (error) {
              if (error.code === 'bump_not_higher') {
                const current = /already (\d+)/.exec(error.message)?.[1] ?? report.next;
                fail(`Must be higher than ${current}.`);
              }
              throw error;
            }
            toast(`The next build gets ${next}`, 'success');
          },
        },
      ],
    });
  }

  load();
  return element;
}

// MARK: Workflow

/** Each workflow by name with what it does, in one line. */
function workflowList(file) {
  const entries = Object.entries(file?.workflows ?? {}).sort(([a], [b]) => a.localeCompare(b));
  return h('ul', { class: 'workflow-summaries', 'aria-label': 'Workflows' }, entries.map(([name, workflow]) => h('li', null,
    h('span', { class: 'workflow-summary-name' }, name),
    h('span', { class: 'workflow-summary-text' }, workflowSummary(workflow)))));
}

function workflowCard(app, signal) {
  const element = card({ class: 'workflow-card' });
  const editor = `/apps/${seg(app.slug)}/workflow`;
  replaceChildren(element, cardTitle('Workflow'), h('div', { class: 'card-loading' }, spinner('Loading workflow')));

  // The workflow stored in Hangar; only without one is GitHub asked whether the repository has a .hangar.yml.
  /** The same wizard as the editor's New Workflow, without opening the editor first. Create saves it here. */
  function createWorkflow(stored) {
    const base = `/apps/${seg(app.slug)}`;
    const groups = betaGroupsStore(base);
    const branches = branchesStore(base);
    openWorkflowWizard({
      app,
      loadSuggestion: () => api.get(`${base}/workflow-suggestion`, { signal }),
      groups,
      branches,
      takenNames: Object.keys(stored.workflows?.workflows ?? {}),
      onCreate: async (created) => {
        const name = created.name.trim();
        const file = stored.workflows ?? { version: 1, workflows: {} };
        const next = await api.put(`${base}/workflow-file`, {
          yaml: workflowToYAML({ ...file, workflows: { ...file.workflows, [name]: toWorkflow(created) } }),
        });
        showStored(next);
        toast(`Created “${name}”`, 'success');
      },
      onBlank: () => navigate(`${base}/workflow?blank=1`),
    });
  }

  function showStored(stored) {
    replaceChildren(element,
      cardTitle('Workflow'),
      workflowList(stored.workflows),
      h('p', { class: 'card-note' }, `Defined in Hangar · updated ${relativeTime(stored.updatedAt)}`),
      h('div', { class: 'card-actions' },
        button('New Workflow…', { kind: 'secondary', onClick: () => createWorkflow(stored) }),
        h('a', { href: editor, 'data-link': true, class: 'button button-secondary' }, 'Edit Workflow')));
  }

  api.get(`/apps/${seg(app.slug)}/workflow-file`, { signal }).then(showStored, (error) => {
    if (error.code === 'aborted') return;
    if (error.code === 'workflow_file_not_found') {
      // No workflow in Hangar: does the repository have its own .hangar.yml (at its default branch)?
      replaceChildren(element, cardTitle('Workflow'), h('div', { class: 'card-loading' }, spinner('Checking the repository')));
      // Remembered by the server for a while, so not a GitHub call on every view.
      api.get(`/apps/${seg(app.slug)}/workflow-source`, { signal }).then(
        (status) => status?.repositoryHasWorkflowFile ?? null,
        (failure) => (failure.code === 'aborted' ? undefined : null),
      ).then(async (repoFile) => {
        if (repoFile === undefined) return;
        if (repoFile) {
          // What the repository's file does, read at its default branch.
          const file = await api.get(`/apps/${seg(app.slug)}/workflows`, { signal }).catch(() => null);
          replaceChildren(element,
            cardTitle('Workflow'),
            file?.workflows ? workflowList(file.workflows) : null,
            h('p', { class: 'card-note' }, 'From the repository’s .hangar.yml. Defining it in Hangar instead takes over from the file.'),
            h('div', { class: 'card-actions' },
              h('a', { href: editor, 'data-link': true, class: 'button button-secondary' }, 'Define in Hangar Instead')));
          return;
        }
        replaceChildren(element,
          cardTitle('Workflow'),
          h('p', { class: 'card-headline' }, 'Not set up yet'),
          h('p', { class: 'card-detail' }, repoFile === false
            ? 'Deploy needs a workflow. Hangar fills it in from the Xcode project in the repository.'
            : 'Hangar fills it in from the Xcode project in the repository.'),
          h('div', { class: 'card-actions' },
            h('a', { href: `${editor}?suggest=1`, 'data-link': true, class: 'button button-primary' }, 'Set Up Workflow')));
      });
      return;
    }
    replaceChildren(element, cardTitle('Workflow'), h('p', { class: 'inline-error-message' }, error.message));
  });
  return element;
}

// MARK: Recent builds

/** The latest builds; `onChange(builds)` runs whenever the list changes (the latest-build card follows it). */
function buildsList(app, signal, onChange) {
  const element = h('div', { class: 'builds' }, h('div', { class: 'list list-loading' }, spinner('Loading builds')));
  let builds = null;
  let rows = [];
  const rowsByID = new Map(); // build id → row, kept so a focused row keeps its focus through live updates

  async function reload() {
    try {
      builds = await api.get(`/builds?app=${seg(app.slug)}&limit=${RECENT_BUILDS}`, { signal });
      render();
    } catch (error) {
      if (error.code === 'aborted') return;
      replaceChildren(element,
        h('div', { class: 'list inline-error' },
          h('p', { class: 'inline-error-message' }, error.message),
          button('Try Again', { kind: 'plain', onClick: reload })));
    }
  }

  function upsert(build) {
    if (!builds) return;
    builds = [build, ...builds.filter((existing) => existing.id !== build.id)]
      .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
      .slice(0, RECENT_BUILDS);
    render();
  }

  function tick() {
    const now = new Date();
    rows.forEach((row) => row.tick(now));
  }

  function render() {
    onChange(builds);
    // Without builds the latest-build card already says so; the empty list would only say it again.
    const sectionElement = element.closest('.section');
    if (sectionElement) sectionElement.hidden = builds.length === 0;
    if (builds.length === 0) {
      rows = [];
      replaceChildren(element);
      return;
    }
    rows = builds.map((build) => {
      let row = rowsByID.get(build.id);
      if (row) {
        if (row.build !== build) row.update(build);
      } else {
        row = buildRow(build);
        rowsByID.set(build.id, row);
      }
      return row;
    });
    const ids = new Set(builds.map((build) => build.id));
    for (const id of rowsByID.keys()) if (!ids.has(id)) rowsByID.delete(id);
    let list = element.querySelector('.build-list');
    if (!list) {
      list = h('ul', { class: 'list build-list' });
      replaceChildren(element, list);
    }
    // Moves rows into order without recreating them (moving a node keeps it, unlike rebuilding it).
    rows.forEach((row, index) => {
      if (list.children[index] !== row.element) list.insertBefore(row.element, list.children[index] ?? null);
    });
    while (list.children.length > rows.length) list.lastChild.remove();
  }

  reload();
  return { element, reload, upsert, tick };
}

// MARK: Remove

function removeCard(app) {
  return card({ class: 'danger-card' },
    h('p', { class: 'card-detail' },
      'Removes the app with its builds, logs, build numbers and variables. Apps in App Store Connect and the repository are not touched.'),
    h('div', { class: 'card-actions' },
      button('Remove App…', { kind: 'destructive', onClick: () => confirmRemoval(app) })));
}

function confirmRemoval(app) {
  const remove = {
    label: 'Remove',
    kind: 'destructive',
    disabled: true,
    onClick: async () => {
      if (input.value.trim() !== app.name) throw new Error(`Type ${app.name} to confirm.`);
      await api.del(`/apps/${seg(app.slug)}`);
      toast(`Removed ${app.name}`, 'success');
      navigate('/');
    },
  };
  const input = h('input', {
    class: 'input', type: 'text', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', autofocus: true,
    onInput: () => {
      remove.disabled = input.value.trim() !== app.name;
      const target = handle.element.querySelector('.sheet-actions .button-destructive');
      if (target) target.disabled = remove.disabled;
    },
  });
  const handle = sheet({
    title: `Remove ${app.name}?`,
    submitOnEnter: false,
    body: h('div', { class: 'form' },
      h('p', { class: 'sheet-message' },
        'Its builds, logs, build numbers and variables are deleted. This cannot be undone.'),
      field({ label: `Type “${app.name}” to confirm`, control: input })),
    actions: [{ label: 'Cancel', kind: 'cancel' }, remove],
  });
}

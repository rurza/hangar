// The app detail page: next build number, workflow source, recent builds, environment and removal.

import { api, ApiError, events, seg } from '../api.js';
import { navigate } from '../router.js';
import {
  button, card, emptyState, field, h, page, relativeTime, replaceChildren, section, sheet, spinner, statusBadge,
  toast,
} from '../ui.js';
import { appIcon } from './apps.js';
import { openDeploySheet } from './deploy.js';
import { variablesEditor } from './variables.js';

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

  const numbers = numbersCard(app, signal);
  const workflow = workflowCard(app, signal);
  const builds = buildsList(app, signal);

  context.onCleanup(events((event) => {
    if (event.type === 'build' && event.build?.appID === app.id) builds.upsert(event.build);
  }, { onReconnect: () => builds.reload() }));

  return page({
    title: app.name,
    subtitle: /^https:\/\//i.test(app.repoURL)
      ? h('a', { href: app.repoURL, target: '_blank', rel: 'noopener noreferrer' }, app.repoURL.replace(/^https:\/\//i, ''))
      : app.repoURL,
    leading: appIcon(app, 'large'),
    actions: button('Deploy', { kind: 'primary', onClick: () => openDeploySheet(app) }),
  },
  h('div', { class: 'detail-grid' }, numbers, workflow),
  section({ title: 'Recent Builds', actions: h('a', { href: `/builds?app=${slug}`, 'data-link': true, class: 'section-link' }, 'All Builds') },
    builds.element),
  section({
    title: 'Environment',
    footer: 'Every job of this app gets these variables. One with the same name as a global variable replaces it.',
  }, variablesEditor({ scope: { app: app.slug }, signal })),
  section({ title: 'Remove App' }, removeCard(app)));
}

/** A card's heading row: the title and an optional trailing control. */
function cardTitle(text, trailing) {
  return h('div', { class: 'card-title-row' }, h('h2', { class: 'card-title' }, text), trailing);
}

// MARK: Next build number

function numbersCard(app, signal) {
  const element = card({ class: 'numbers-card' });
  const path = `/apps/${seg(app.slug)}/numbers`;

  function loading() {
    replaceChildren(element, cardTitle('Next Build Number'), h('div', { class: 'card-loading' }, spinner('Loading numbers')));
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
      cardTitle('Next Build Number', button('Raise…', { kind: 'plain', onClick: () => raise(report) })),
      h('p', { class: 'big-number' }, String(report.next)),
      h('dl', { class: 'facts' },
        fact('Highest in Hangar', report.highestHangar),
        fact('Highest in App Store Connect', report.highestAppStoreConnect),
        fact('Last Xcode Cloud run', report.lastXcodeCloudRun)),
      report.inFlight
        ? h('p', { class: 'card-note' }, 'A build is in progress and has already taken its number.')
        : null);
  }

  function renderError(error) {
    const needsKey = error.code === 'app_store_connect_not_configured';
    replaceChildren(element,
      cardTitle('Next Build Number'),
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

function workflowCard(app, signal) {
  const element = card({ class: 'workflow-card' });
  const editor = `/apps/${seg(app.slug)}/workflow`;
  replaceChildren(element, cardTitle('Workflow'), h('div', { class: 'card-loading' }, spinner('Loading workflow')));

  // Only the workflow stored in Hangar is asked for: the repository's .hangar.yml would mean a GitHub request on
  // every view of this page.
  api.get(`/apps/${seg(app.slug)}/workflow-file`, { signal }).then((stored) => {
    const names = Object.keys(stored.workflows?.workflows ?? {}).sort();
    replaceChildren(element,
      cardTitle('Workflow'),
      h('p', { class: 'card-headline' }, 'Defined in Hangar'),
      h('p', { class: 'card-detail' }, `Updated ${relativeTime(stored.updatedAt)}`),
      names.length ? h('ul', { class: 'chips', 'aria-label': 'Workflows' }, names.map((name) => h('li', { class: 'chip' }, name))) : null,
      h('div', { class: 'card-actions' },
        h('a', { href: editor, 'data-link': true, class: 'button button-secondary' }, 'Edit Workflow')));
  }, (error) => {
    if (error.code === 'aborted') return;
    if (error.code === 'workflow_file_not_found') {
      replaceChildren(element,
        cardTitle('Workflow'),
        h('p', { class: 'card-headline' }, 'From .hangar.yml in the repository (if present)'),
        h('p', { class: 'card-detail' }, 'Define the workflow in Hangar to build without a file in the repository.'),
        h('div', { class: 'card-actions' },
          h('a', { href: editor, 'data-link': true, class: 'button button-secondary' }, 'Define in Hangar')));
      return;
    }
    replaceChildren(element, cardTitle('Workflow'), h('p', { class: 'inline-error-message' }, error.message));
  });
  return element;
}

// MARK: Recent builds

function buildsList(app, signal) {
  const element = h('div', { class: 'builds' }, h('div', { class: 'list list-loading' }, spinner('Loading builds')));
  let builds = null;

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

  function render() {
    if (builds.length === 0) {
      replaceChildren(element, h('div', { class: 'list' },
        emptyState({
          title: 'No Builds Yet',
          message: 'Deploy a workflow and its build shows up here.',
          action: button('Deploy', { kind: 'primary', onClick: () => openDeploySheet(app) }),
        })));
      return;
    }
    replaceChildren(element, h('ul', { class: 'list' }, builds.map((build) => h('li', null,
      h('a', { href: `/builds/${seg(build.id)}`, 'data-link': true, class: 'row build-row' },
        h('span', { class: 'build-number' }, String(build.buildNumber)),
        h('span', { class: 'row-main' },
          h('span', { class: 'row-title' }, build.workflow),
          h('span', { class: 'row-detail build-ref' }, `${build.ref} · ${String(build.commit ?? '').slice(0, 7)}`)),
        h('span', { class: 'build-trailing' },
          statusBadge(build.status),
          h('span', { class: 'row-detail' }, relativeTime(build.createdAt))))))));
  }

  reload();
  return { element, reload, upsert };
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

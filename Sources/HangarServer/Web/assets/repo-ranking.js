// Orders the repository picker's list. Pure functions, no DOM, so a test runs them in JXA.

/** Lowercase letters and digits only: "Hourly-Beep" and "hourly_beep" both become "hourlybeep". */
function normalize(text) {
  return String(text ?? '').toLowerCase().replace(/[^a-z0-9]/g, '');
}

/** How well `repo` matches the app's name and bundle ID: 0 when it does not at all. */
function scoreRepository(repo, { name, bundleID } = {}) {
  const repoName = normalize(String(repo.fullName ?? '').split('/').pop());
  if (!repoName) return 0;
  const app = normalize(name);
  const bundleTail = normalize(String(bundleID ?? '').split('.').pop());
  if (app && repoName === app) return 100;
  if (app.length >= 3 && (repoName.startsWith(app) || app.startsWith(repoName))) return 60;
  if (app.length >= 3 && (repoName.includes(app) || (repoName.length >= 3 && app.includes(repoName)))) return 40;
  if (bundleTail && repoName === bundleTail) return 30;
  if (bundleTail.length >= 3 && (repoName.includes(bundleTail) || bundleTail.includes(repoName))) return 20;
  return 0;
}

function pushedTime(repo) {
  const time = Date.parse(repo.pushedAt ?? '');
  return Number.isNaN(time) ? 0 : time;
}

/**
 * The repositories best match first (see `scoreRepository`), then the most recently pushed; archived ones last.
 * Without `hints` (no app chosen yet) that is plain recency. Returns `{ repos, suggested }`: `suggested` is the top
 * unarchived repository when it scored, else null.
 */
function rankRepositories(repos, hints = {}) {
  const scored = (repos ?? []).map((repo, index) => ({ repo, index, score: scoreRepository(repo, hints) }));
  scored.sort((a, b) => (Number(Boolean(a.repo.archived)) - Number(Boolean(b.repo.archived)))
    || (b.score - a.score)
    || (pushedTime(b.repo) - pushedTime(a.repo))
    || (a.index - b.index));
  const top = scored[0];
  return {
    repos: scored.map((entry) => entry.repo),
    suggested: top && !top.repo.archived && top.score > 0 ? top.repo : null,
  };
}

/**
 * App Store Connect apps for a detected app that matched none by bundle ID: the closest name or bundle ID first
 * (the same scores as repositories), then by name. Apps already in Hangar go last.
 */
function rankAppStoreConnectApps(apps, detected = {}) {
  const hints = { name: detected.name, bundleID: (detected.bundleIDs ?? [])[0] };
  const score = (app) => Math.max(
    scoreRepository({ fullName: app.name }, hints),
    scoreRepository({ fullName: String(app.bundleID ?? '').split('.').pop() }, hints));
  return (apps ?? [])
    .map((app) => ({ app, score: score(app) }))
    .sort((a, b) => (Number(Boolean(a.app.registered)) - Number(Boolean(b.app.registered)))
      || (b.score - a.score)
      || String(a.app.name).localeCompare(String(b.app.name)))
    .map((entry) => entry.app);
}

/** The repositories whose name or description contains every word of `query`. */
function filterRepositories(repos, query) {
  const words = String(query ?? '').toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return repos;
  return repos.filter((repo) => {
    const text = `${repo.fullName ?? ''} ${repo.description ?? ''}`.toLowerCase();
    return words.every((word) => text.includes(word));
  });
}

/** `owner/repo` of a `https://github.com/owner/repo(.git)(/)` URL, else null. */
function parseRepositoryURL(text) {
  const match = /^https:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+?)(?:\.git)?\/?$/.exec(String(text ?? '').trim());
  if (!match || ['.', '..'].includes(match[1]) || ['.', '..'].includes(match[2])) return null;
  return { owner: match[1], repo: match[2], fullName: `${match[1]}/${match[2]}` };
}

export { filterRepositories, normalize, parseRepositoryURL, rankAppStoreConnectApps, rankRepositories, scoreRepository };

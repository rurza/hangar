// What the build page's log shows, as plain values: lines grouped by step and classified (errors, warnings, the
// `▸` task lines the worker writes for xcodebuild), filters, search and shortened paths. No DOM, no imports, and a
// single final `export` line, so the tests can load this file in JXA after stripping that line.

const TASK_MARKER = '▸ ';
/** Lines a step keeps in memory; older ones are dropped (the full log has them). */
const STEP_LINE_LIMIT = 50000;

/**
 * A line's kind: `task` (a `▸` line), `error`, `warning` and `note` (a diagnostic's first line, which the counts and
 * jump links use), `failed` and `succeeded` (xcodebuild's `** … **` banners), `excerpt` (a compiler's source excerpt
 * under a diagnostic), or `plain`.
 */
function lineKind(text) {
  if (text.startsWith(TASK_MARKER)) return 'task';
  if (/^\*\* .+ (FAILED|INTERRUPTED|CANCELLED) \*\*$/.test(text)) return 'failed';
  if (/^\*\* .+ SUCCEEDED \*\*$/.test(text)) return 'succeeded';
  // A diagnostic starts at the line's start: `error: …`, `File.swift:1:2: error: …`, `clang: error: …`. Indented
  // or excerpt lines (`   |  `- error: …`) repeat it and are not counted again.
  const diagnostic = /^(?:[^\s|][^|]*?: )?(fatal error|error|warning|note): /.exec(text);
  if (diagnostic) return diagnostic[1] === 'fatal error' ? 'error' : diagnostic[1];
  if (/^Test Case '.*' failed/.test(text) || /^✗ /.test(text) || /^✘ /.test(text)) return 'error';
  if (/^\s*\d*\s+\|/.test(text)) return 'excerpt';
  return 'plain';
}

/** Whether a line of this kind is counted and reachable from the jump links. */
function isIssue(kind) {
  return kind === 'error' || kind === 'warning';
}

// MARK: Steps

/** An empty log: steps in the order their first line arrived. */
function createLog() {
  return { steps: [], byName: {} };
}

/**
 * Adds stream entries (`{t, step, line}`) to `log` and returns the names of the steps that changed, in order. A
 * step keeps at most `STEP_LINE_LIMIT` lines, counting those it dropped in `dropped`.
 */
function appendEntries(log, entries) {
  const changed = [];
  for (const entry of entries) {
    if (!entry || typeof entry.line !== 'string') continue;
    const name = typeof entry.step === 'string' ? entry.step : '';
    let step = log.byName[name];
    if (!step) {
      step = { name, lines: [], errors: 0, warnings: 0, dropped: 0, nextIndex: 0 };
      log.byName[name] = step;
      log.steps.push(step);
    }
    const kind = lineKind(entry.line);
    step.lines.push({ index: step.nextIndex, t: entry.t, text: entry.line, kind });
    step.nextIndex += 1;
    if (kind === 'error') step.errors += 1;
    if (kind === 'warning') step.warnings += 1;
    if (step.lines.length > STEP_LINE_LIMIT) {
      const removed = step.lines.splice(0, step.lines.length - STEP_LINE_LIMIT);
      step.dropped += removed.length;
      for (const line of removed) {
        if (line.kind === 'error') step.errors -= 1;
        if (line.kind === 'warning') step.warnings -= 1;
      }
    }
    if (!changed.includes(name)) changed.push(name);
  }
  return changed;
}

/** Errors and warnings across the log. */
function issueTotals(log) {
  return log.steps.reduce((totals, step) => ({
    errors: totals.errors + step.errors, warnings: totals.warnings + step.warnings,
  }), { errors: 0, warnings: 0 });
}

/** Every line of `kind` (`error` or `warning`), in log order, as `{step, index}`. */
function issuePositions(log, kind) {
  const positions = [];
  for (const step of log.steps) {
    for (const line of step.lines) if (line.kind === kind) positions.push({ step: step.name, index: line.index });
  }
  return positions;
}

/**
 * Which steps start expanded: the failed ones; while the job runs, the running one; for a failed job whose steps
 * name no failure (an old job), the last step that logged an error, else the last step. `job.steps` gives the
 * statuses; a step still `running` in an ended job counts as failed.
 */
function defaultOpenSteps(log, job) {
  const ended = ['succeeded', 'failed', 'cancelled'].includes(job?.status);
  const statuses = {};
  for (const step of job?.steps ?? []) {
    if (step && typeof step.name === 'string') statuses[step.name] = step.status;
  }
  const names = log.steps.map((step) => step.name);
  const open = names.filter((name) => {
    const status = statuses[name];
    if (status === 'failed') return true;
    if (status === 'running') return ended ? job.status !== 'cancelled' : true;
    return false;
  });
  if (open.length === 0 && job?.status === 'failed' && names.length) {
    const withErrors = log.steps.filter((step) => step.errors > 0);
    open.push((withErrors[withErrors.length - 1] ?? log.steps[log.steps.length - 1]).name);
  }
  return open;
}

// MARK: Filters

/**
 * The lines of `step` to show: all of them, only errors and warnings (`issuesOnly`), only those containing `query`
 * (case-insensitive, in the line as logged or as shown), or both. Filtered lines keep the `▸` task line they belong
 * to, so each issue says which task it came from.
 */
function visibleLines(step, { issuesOnly = false, query = '' } = {}) {
  const needle = query.trim().toLowerCase();
  if (!issuesOnly && !needle) return step.lines;
  const shown = [];
  let task = null;
  let taskShown = false;
  for (const line of step.lines) {
    if (line.kind === 'task') {
      task = line;
      taskShown = false;
    } else if (line.kind === 'failed' || line.kind === 'succeeded') {
      // xcodebuild's summary: what follows belongs to no task.
      task = null;
    }
    const matches = (!issuesOnly || isIssue(line.kind))
      && (!needle || line.text.toLowerCase().includes(needle) || displayText(line.text).toLowerCase().includes(needle));
    if (!matches) continue;
    if (task && !taskShown && task !== line) shown.push(task);
    if (task) taskShown = true;
    shown.push(line);
  }
  return shown;
}

// MARK: Paths

// `Application Support` is the one folder with a space that worker paths commonly pass through.
const PATH_PATTERN = /(?:\/(?:Application Support|[\w.@+~%-]+)){2,}\/?/g;

/** Prefixes replaced by something short, in order: the repository's checkout becomes nothing (paths relative to it). */
const PATH_RULES = [
  [/^.*\/workspaces\/[^/]+\/repository\//, ''],
  [/^.*\/workspaces\/[^/]+\/DerivedData\/SourcePackages\/checkouts\//, 'SourcePackages/'],
  [/^.*\/workspaces\/[^/]+\/DerivedData\//, 'DerivedData/'],
  [/^.*\/workspaces\/[^/]+\/DerivedData$/, 'DerivedData'],
  [/^\/Applications\/Xcode[^/]*\.app\/Contents\/Developer\/Platforms\/[^/]+\/Developer\/SDKs\/([^/]+)\//, '$1/'],
  [/^\/Applications\/Xcode[^/]*\.app\/Contents\/Developer\/Toolchains\/[^/]+\/usr\/bin\//, ''],
  [/^\/Applications\/Xcode[^/]*\.app\/Contents\/Developer\//, 'Xcode/'],
  [/^.*\/jobs\/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\//, 'job/'],
];

/** `path` shortened by the first rule that applies, or null when none does (or nothing would be left). */
function shortPath(path) {
  for (const [pattern, replacement] of PATH_RULES) {
    if (pattern.test(path)) {
      const short = path.replace(pattern, replacement);
      return short && short !== path ? short : null;
    }
  }
  return null;
}

/**
 * `text` as segments to render: `{text}` for plain text and `{text, title}` for a shortened path, whose `title` is
 * the full path (shown on hover).
 */
function pathSegments(text) {
  const segments = [];
  let last = 0;
  PATH_PATTERN.lastIndex = 0;
  let match;
  while ((match = PATH_PATTERN.exec(text)) !== null) {
    // Only a whole path: not one starting inside a word ("…/Application Support/…" read from "/Support").
    if (match.index > 0 && /[\w.~-]/.test(text[match.index - 1])) continue;
    const short = shortPath(match[0]);
    if (short === null) continue;
    if (match.index > last) segments.push({ text: text.slice(last, match.index) });
    segments.push({ text: short, title: match[0] });
    last = match.index + match[0].length;
  }
  if (last < text.length || segments.length === 0) segments.push({ text: text.slice(last) });
  return segments;
}

/** The line as shown, its paths shortened. */
function displayText(text) {
  return pathSegments(text).map((segment) => segment.text).join('');
}

/**
 * The segments of `text` to render with `query` highlighted: like `pathSegments`, each split further into pieces
 * with `mark: true` where the query matches (case-insensitive).
 */
function lineSegments(text, query = '') {
  const segments = pathSegments(text);
  const needle = query.trim().toLowerCase();
  if (!needle) return segments;
  const result = [];
  for (const segment of segments) {
    const lower = segment.text.toLowerCase();
    let from = 0;
    let at = lower.indexOf(needle);
    while (at !== -1) {
      if (at > from) result.push({ ...segment, text: segment.text.slice(from, at) });
      result.push({ ...segment, text: segment.text.slice(at, at + needle.length), mark: true });
      from = at + needle.length;
      at = lower.indexOf(needle, from);
    }
    if (from < segment.text.length) result.push({ ...segment, text: segment.text.slice(from) });
  }
  return result;
}

/** "1 error", "12 warnings". */
function countLabel(count, noun) {
  return `${count} ${noun}${count === 1 ? '' : 's'}`;
}

export { appendEntries, countLabel, createLog, defaultOpenSteps, displayText, isIssue, issuePositions, issueTotals, lineKind, lineSegments, pathSegments, shortPath, visibleLines, TASK_MARKER };

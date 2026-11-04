// The Hangar REST API (docs/api.md): JSON requests under /api/v1 and the two server-sent event streams.

const BASE = '/api/v1';
const TIMEOUT_MS = 30_000;

/** A failed request: the HTTP status (0 when the server was not reached) and the server's `{code, message}`. */
export class ApiError extends Error {
  constructor(status, code, message) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
  }
}

/** A signal that aborts when any of `signals` does (AbortSignal.any where available). */
function anySignal(signals) {
  if (typeof AbortSignal.any === 'function') return AbortSignal.any(signals);
  const controller = new AbortController();
  for (const signal of signals) {
    if (signal.aborted) {
      controller.abort(signal.reason);
      break;
    }
    signal.addEventListener('abort', () => controller.abort(signal.reason), { once: true });
  }
  return controller.signal;
}

async function request(method, path, body, { signal } = {}) {
  const timeout = new AbortController();
  const timer = setTimeout(() => timeout.abort(), TIMEOUT_MS);
  const headers = { Accept: 'application/json' };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  try {
    const response = await fetch(BASE + path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: signal ? anySignal([signal, timeout.signal]) : timeout.signal,
      credentials: 'same-origin',
    });
    const text = await response.text();
    if (!response.ok) throw errorFrom(response, text);
    if (response.status === 204 || text === '') return null;
    return JSON.parse(text);
  } catch (error) {
    if (error instanceof ApiError) throw error;
    // The caller's abort wins over the timeout, so a page that was left never reports a timeout.
    if (signal?.aborted) throw new ApiError(0, 'aborted', 'The request was cancelled.');
    if (timeout.signal.aborted) throw new ApiError(0, 'timeout', 'Hangar did not answer within 30 seconds.');
    if (error instanceof SyntaxError) throw new ApiError(0, 'invalid_response', 'Hangar sent a response that is not JSON.');
    throw new ApiError(0, 'network_error', 'Hangar cannot be reached. Check that the server is running.');
  } finally {
    clearTimeout(timer);
  }
}

function errorFrom(response, text) {
  try {
    const body = JSON.parse(text);
    if (body && typeof body.code === 'string') {
      return new ApiError(response.status, body.code, typeof body.message === 'string' ? body.message : body.code);
    }
  } catch {
    // Not JSON (a proxy's error page, for example): fall through to a synthesized error.
  }
  const reason = response.statusText ? ` ${response.statusText}` : '';
  return new ApiError(response.status, `http_${response.status}`, `The server answered ${response.status}${reason}.`);
}

/**
 * JSON calls; `path` starts with `/` and is relative to `/api/v1`. Each resolves to the decoded body or null.
 * `options.signal` (e.g. the router's `context.signal`) cancels the call: it then rejects with code `aborted`,
 * while a call that runs out of time rejects with code `timeout`.
 */
export const api = {
  get: (path, options) => request('GET', path, undefined, options),
  post: (path, body, options) => request('POST', path, body, options),
  put: (path, body, options) => request('PUT', path, body, options),
  del: (path, options) => request('DELETE', path, undefined, options),
};

/** Encodes one path segment, e.g. `api.get(\`/apps/${seg(slug)}\`)`. */
export const seg = encodeURIComponent;

// MARK: Server-sent events

const RECONNECT_MIN_MS = 1000;
const RECONNECT_MAX_MS = 15_000;

/**
 * An EventSource that reconnects with backoff after any error (the browser gives up on some on its own) and is
 * closed for good by the returned function. `listeners` maps event names to `(data) => void`, with data parsed
 * from JSON. `onReopen` runs when a connection opens after an error or a pause, so callers can reload what they
 * missed. With `onFailBeforeOpen`, a first connection that fails without ever opening (a 404, say) is not retried:
 * the stream closes and `onFailBeforeOpen()` runs instead.
 *
 * Over HTTP/1.1 a browser allows only six connections per host, shared by every tab, and each open EventSource
 * holds one. So the stream is closed while the tab is hidden and opened again when it is visible, which counts as
 * a reconnect: `onReopen` reloads what changed meanwhile.
 */
function stream(url, listeners, { onReopen, onConnect, onFailBeforeOpen } = {}) {
  let source = null;
  let timer = null;
  let closed = false;
  let delay = RECONNECT_MIN_MS;
  let failed = false;
  let everOpened = false;
  let paused = false;

  function open() {
    timer = null;
    if (closed || paused) return;
    onConnect?.();
    source = new EventSource(url);
    source.addEventListener('open', () => {
      everOpened = true;
      delay = RECONNECT_MIN_MS;
      if (failed) {
        failed = false;
        onReopen?.();
      }
    });
    source.addEventListener('error', () => {
      if (closed) return;
      source.close();
      source = null;
      if (!everOpened && onFailBeforeOpen) {
        teardown();
        onFailBeforeOpen();
        return;
      }
      failed = true;
      timer = setTimeout(open, delay);
      delay = Math.min(delay * 2, RECONNECT_MAX_MS);
    });
    for (const [name, listener] of Object.entries(listeners)) {
      source.addEventListener(name, (event) => {
        if (closed) return;
        let data;
        try {
          data = JSON.parse(event.data);
        } catch {
          return;
        }
        listener(data);
      });
    }
  }

  // Hidden: drop the connection (and any pending retry). Visible again: reconnect at once and reload.
  function onVisibilityChange() {
    if (closed) return;
    if (document.visibilityState === 'hidden') {
      if (paused) return;
      paused = true;
      failed = true;
      if (timer) clearTimeout(timer);
      timer = null;
      source?.close();
      source = null;
    } else if (paused) {
      paused = false;
      delay = RECONNECT_MIN_MS;
      if (!source && !timer) open();
    }
  }

  function teardown() {
    closed = true;
    if (timer) clearTimeout(timer);
    timer = null;
    source?.close();
    source = null;
    document.removeEventListener('visibilitychange', onVisibilityChange);
  }

  document.addEventListener('visibilitychange', onVisibilityChange);
  if (document.visibilityState === 'hidden') {
    // Opened in a background tab: connect once it is shown, reloading what the caller fetched meanwhile.
    paused = true;
    failed = true;
  } else {
    open();
  }
  return function close() {
    if (closed) return;
    teardown();
  };
}

/**
 * Every build, job and machine change: `onEvent` gets the `ServerEvent`, e.g. `{type: "build", build: {...}}`.
 * Pass `onReconnect` to reload state after the stream dropped (events sent meanwhile are lost). Returns the
 * function that closes the stream; register it with the router's `onCleanup`.
 */
export function events(onEvent, { onReconnect } = {}) {
  const deliver = (data) => onEvent(data);
  return stream(`${BASE}/events`, { build: deliver, job: deliver, machine: deliver }, { onReopen: onReconnect });
}

/**
 * Follows a job's log: `onEntries([LogEntry])` for the stored entries and then each new batch, `onEnd(job)` once
 * the job has finished, after which the stream is closed. `step` (optional) limits it to one step. After a
 * dropped connection the server replays the log from the start; entries already delivered are skipped. When the
 * stream cannot be opened at all (an unknown job, say) it is not retried and `onError(ApiError)` runs. Returns
 * the function that stops following.
 */
export function followLog(jobID, step, onEntries, onEnd, onError) {
  const query = new URLSearchParams({ follow: '1' });
  if (step) query.set('step', step);
  let delivered = 0;
  let toSkip = 0;
  let stopped = false;
  const close = stream(`${BASE}/jobs/${seg(jobID)}/log?${query}`, {
    log: (entries) => {
      if (!Array.isArray(entries)) return;
      const skipped = Math.min(toSkip, entries.length);
      toSkip -= skipped;
      const fresh = skipped ? entries.slice(skipped) : entries;
      delivered += fresh.length;
      if (fresh.length) onEntries(fresh);
    },
    end: (job) => {
      stop();
      onEnd?.(job);
    },
  }, {
    // Every connection starts with the whole stored log again.
    onConnect: () => { toSkip = delivered; },
    // EventSource does not expose the status, so ask for the job to learn why (job_not_found, for example).
    onFailBeforeOpen: () => {
      request('GET', `/jobs/${seg(jobID)}`).then(
        () => new ApiError(0, 'stream_unavailable', 'The log stream could not be opened.'),
        (error) => error,
      ).then((error) => {
        if (!stopped) onError?.(error);
      });
    },
  });
  function stop() {
    stopped = true;
    close();
  }
  return stop;
}

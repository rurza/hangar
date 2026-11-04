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

async function request(method, path, body) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  const headers = { Accept: 'application/json' };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  try {
    const response = await fetch(BASE + path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: controller.signal,
      credentials: 'same-origin',
    });
    const text = await response.text();
    if (!response.ok) throw errorFrom(response, text);
    if (response.status === 204 || text === '') return null;
    return JSON.parse(text);
  } catch (error) {
    if (error instanceof ApiError) throw error;
    if (controller.signal.aborted) {
      throw new ApiError(0, 'timeout', 'Hangar did not answer within 30 seconds.');
    }
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

/** JSON calls; `path` starts with `/` and is relative to `/api/v1`. Each resolves to the decoded body or null. */
export const api = {
  get: (path) => request('GET', path),
  post: (path, body) => request('POST', path, body),
  put: (path, body) => request('PUT', path, body),
  del: (path) => request('DELETE', path),
};

/** Encodes one path segment, e.g. `api.get(\`/apps/${seg(slug)}\`)`. */
export const seg = encodeURIComponent;

// MARK: Server-sent events

const RECONNECT_MIN_MS = 1000;
const RECONNECT_MAX_MS = 15_000;

/**
 * An EventSource that reconnects with backoff after any error (the browser gives up on some on its own) and is
 * closed for good by the returned function. `listeners` maps event names to `(data) => void`, with data parsed
 * from JSON. `onReopen` runs when a connection opens after an error, so callers can reload what they missed.
 */
function stream(url, listeners, { onReopen, onConnect } = {}) {
  let source = null;
  let timer = null;
  let closed = false;
  let delay = RECONNECT_MIN_MS;
  let failed = false;

  function open() {
    timer = null;
    if (closed) return;
    onConnect?.();
    source = new EventSource(url);
    source.addEventListener('open', () => {
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

  open();
  return function close() {
    if (closed) return;
    closed = true;
    if (timer) clearTimeout(timer);
    source?.close();
    source = null;
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
 * dropped connection the server replays the log from the start; entries already delivered are skipped. Returns
 * the function that stops following.
 */
export function followLog(jobID, step, onEntries, onEnd) {
  const query = new URLSearchParams({ follow: '1' });
  if (step) query.set('step', step);
  let delivered = 0;
  let toSkip = 0;
  let close = null;
  close = stream(`${BASE}/jobs/${seg(jobID)}/log?${query}`, {
    log: (entries) => {
      if (!Array.isArray(entries)) return;
      const skipped = Math.min(toSkip, entries.length);
      toSkip -= skipped;
      const fresh = skipped ? entries.slice(skipped) : entries;
      delivered += fresh.length;
      if (fresh.length) onEntries(fresh);
    },
    end: (job) => {
      close();
      onEnd?.(job);
    },
  }, {
    // Every connection starts with the whole stored log again.
    onConnect: () => { toSkip = delivered; },
  });
  return close;
}

// Query strings for API URLs. Each name and value goes through encodeURIComponent, so a space is `%20` and a plus
// `%2B`: unambiguous for any decoder (the server reads `+` as a space, as a form does). Use this, not hand-built
// `?a=${value}` strings, for anything a person can name: workflows, branches, paths.

/** `{workflow: 'UX Review', ref: 'main'}` → `workflow=UX%20Review&ref=main`; null, undefined and false are left out. */
function queryString(params) {
  return Object.entries(params)
    .filter(([, value]) => value !== null && value !== undefined && value !== false)
    .map(([name, value]) => `${encodeURIComponent(name)}=${encodeURIComponent(String(value))}`)
    .join('&');
}

/** `path` with `?query` appended, or `path` alone when no parameter is left. */
function withQuery(path, params) {
  const query = queryString(params);
  return query ? `${path}?${query}` : path;
}

export { queryString, withQuery };

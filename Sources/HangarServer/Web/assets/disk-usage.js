// What Hangar's files take on a Mac (a machine report's `diskUsage`, the server's in Settings) and how long the
// server keeps build files, as the Machines page and Settings say it. No imports, so the tests run it in JXA.

/** "51 GB", "1.3 GB", "120 MB": decimal, as Finder counts. */
function gbText(gb) {
  if (typeof gb !== 'number' || !Number.isFinite(gb) || gb < 0) return '–';
  if (gb >= 10) return `${Math.round(gb)} GB`;
  if (gb >= 1) return `${gb.toFixed(1)} GB`;
  return `${Math.round(gb * 1000)} MB`;
}

/**
 * `{ value: "51 GB", detail: "VM images 49 GB · Workspaces 1.3 GB" }`, or null before the first measurement (and
 * from an older worker or server).
 */
function diskUsageText(usage) {
  if (!usage || typeof usage.totalGB !== 'number') return null;
  const parts = (Array.isArray(usage.parts) ? usage.parts : []).map((part) => `${part.label} ${gbText(part.gb)}`);
  return { value: gbText(usage.totalGB), detail: parts.join(' · ') };
}

/** What the server keeps: "Keeps each app’s last 5 builds and every build from the last 7 days, up to 10 GB in all." */
function retentionText(storage) {
  if (!storage) return '';
  const builds = storage.keepBuildsPerApp === 1 ? 'latest build' : `last ${storage.keepBuildsPerApp} builds`;
  const days = storage.keepDays === 1 ? 'day' : `${storage.keepDays} days`;
  return `Keeps the logs and artifacts of each app’s ${builds} and of every build from the last ${days}, `
    + `up to ${gbText(storage.maxGB)} in all; past that the oldest go first.`;
}

export { diskUsageText, gbText, retentionText };

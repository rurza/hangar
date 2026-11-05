// What the build page says about a job and its steps, as plain values: no DOM, no imports, and a single final
// `export` line, so the tests can load this file in JXA after stripping that line.

const STEP_STATUS_WORDS = {
  pending: 'pending', running: 'running', succeeded: 'succeeded', failed: 'failed', skipped: 'skipped',
  warning: 'succeeded with warnings', cancelled: 'cancelled',
};

/**
 * The status a step shows. A step still `running` in a job that ended was cut off: cancelled in a cancelled job,
 * failed otherwise (a worker that lost the job).
 */
function stepDisplayStatus(step, job) {
  const ended = ['succeeded', 'failed', 'cancelled'].includes(job?.status);
  if (step.status === 'running' && ended) return job.status === 'cancelled' ? 'cancelled' : 'failed';
  return step.status;
}

/** The words a screen reader hears for a step's status. */
function stepStatusWords(status) {
  return STEP_STATUS_WORDS[status] ?? status;
}

/**
 * The line under a step's name: why it failed (the first error in its log), its warnings (unless its stages show
 * them), or why it was stopped. Nothing for a step that went fine or has not ended.
 */
function stepDetail(step, job) {
  const status = stepDisplayStatus(step, job);
  if (!['failed', 'warning', 'cancelled'].includes(status)) return null;
  // A step's warnings are its stages' details, which are listed under it already.
  if (status === 'warning' && stepStages(step, job).some((stage) => stage.detail)) return null;
  const detail = typeof step.detail === 'string' ? step.detail.trim() : '';
  return detail || null;
}

/** A step's stages as `{name, status, detail}`, or an empty list. A stage still running in an ended job is shown
 * like the step. */
function stepStages(step, job) {
  if (!Array.isArray(step.stages)) return [];
  const ended = ['succeeded', 'failed', 'cancelled'].includes(job?.status);
  return step.stages
    .filter((stage) => stage && typeof stage.name === 'string')
    .map((stage) => ({
      name: stage.name,
      status: stage.status === 'running' && ended ? (job.status === 'cancelled' ? 'cancelled' : 'failed') : stage.status,
      detail: typeof stage.detail === 'string' && stage.detail.trim() ? stage.detail.trim() : null,
    }));
}

/**
 * The job's "where and with what" line: "rurzomac-mini · Worker 0.5.0 (a1c9b45d) · Xcode 27.2 (27B48)". `machine`
 * is the machine as the server lists it now; a removed machine falls back to the name the job kept.
 */
function jobRunLine(job, machine) {
  const info = job?.runInfo ?? {};
  const name = machine?.name ?? info.machineName ?? (job?.machineID ? 'Unknown machine' : 'No machine yet');
  const parts = [name];
  if (info.workerVersion) parts.push(`Worker ${info.workerVersion}`);
  if (info.xcodeVersion) parts.push(`Xcode ${info.xcodeVersion}${info.xcodeBuild ? ` (${info.xcodeBuild})` : ''}`);
  return parts.join(' · ');
}

export { jobRunLine, stepDetail, stepDisplayStatus, stepStages, stepStatusWords };

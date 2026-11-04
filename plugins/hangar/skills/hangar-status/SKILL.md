---
name: hangar-status
description: Use when asked what Hangar is building, why a build is queued or failed, or for build logs
---

# Inspect Hangar builds

This skill only drives the `hangar` CLI and only reads. It does nothing the CLI cannot.

## Prerequisites

- `hangar` is on PATH.
- `HANGAR_SERVER` is set to the Hangar server's URL.

If either is missing, say so and stop.

## Commands

- What is running or queued: `hangar status` (add `--json` for fields). Lists every queued or running build.
- One build: `hangar status <id> --json`. Read `status`, `jobs[].status`, `jobs[].steps`, `jobs[].queueNote`, `jobs[].failureReason` and `jobs[].outputs`. This exits 1 for a failed build and 2 for a cancelled one: read the output anyway, it is not a command error.
- Recent builds: `hangar builds [--app <app>] [--limit <n>] --json`, to find a build id.
- Why a job is queued: the job's `queueNote` in `hangar status`. For machine context run `hangar machines list` (or `--json`: `name`, `lastSeenAt`, `report.runningJobIDs`, `report.xcodes`).
- Why a build failed: find the failed job and step in `hangar status <id> --json`, then `hangar logs <id> --step <failed step> --tail 80`. `<id>` can be a job id or a build id; use the job id when a build has several jobs.
- Whole log: `hangar logs <id>` (add `--tail <n>` to limit).

## Reporting

Summarise in a few lines: app, build number, status, per job platform and current or failed step. For queued jobs give the `queueNote` and what the machines list shows. For failures quote the relevant log lines and `failureReason`. Say only what the log, notes and JSON show; do not speculate about causes beyond them. If the log is not enough, say so and offer a larger `--tail`.

## Never

- Never start, cancel or change builds, variables, settings or machines unless the user explicitly asks. Cancelling is `hangar cancel <build-id>`, and only on request.
- Never print or ask for secret values. If a log excerpt contains one, mask it.

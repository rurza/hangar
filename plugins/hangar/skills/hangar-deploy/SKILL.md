---
name: hangar-deploy
description: Use when asked to build, deploy or ship an app to TestFlight with Hangar (not Xcode Cloud)
---

# Deploy an app to TestFlight with Hangar

This skill only drives the `hangar` CLI. It does nothing the CLI cannot.

## Prerequisites

- `hangar` is on PATH.
- `HANGAR_SERVER` is set to the Hangar server's URL.

If either is missing, say so and stop. Do not guess a server.

## Xcode Cloud

If the user says "Xcode Cloud", stop and say this skill never starts Xcode Cloud builds. Do not run any command.

## Steps

1. Resolve the app: `hangar apps list --json` (array of apps with `slug`, `name`, `id`). Match the user's words to one app. If several fit or none does, ask which.
2. Resolve the workflow: `hangar workflows <app> --json [--ref <ref>]`. The workflow names are the keys of `.workflows.workflows`. Ask when ambiguous. Default ref is `main`; use the ref the user names.
3. Check the numbers: `hangar numbers <app>` (add `--json` to read fields). Show the user `next`. Warn, and ask whether to continue, when:
   - `inFlight` is true (another build of this app is queued or running), or
   - `lastXcodeCloudRun` is not null and is `>= next` (Xcode Cloud has used a number Hangar would hand out).
4. Deploy: `hangar deploy <app> <workflow> --ref <ref> [--machine <machine>] --json --no-wait`. Add `--machine` only if the user asked for one. This returns as soon as the build is queued; read `id` and `buildNumber` from the JSON.
5. Poll `hangar status <id> --json` every 30 seconds (`sleep 30` between calls) until `status` is `succeeded`, `failed` or `cancelled`. `queued` and `running` are not terminal.
   - `status <id>` exits 1 for a failed build and 2 for a cancelled one, even with `--json`. A non-zero exit is not a command error: read the JSON from stdout and go by `status`.
   - If the command cannot reach the server, retry on the next poll. Do not report a failure; the build may still be running. Report lost contact only after several consecutive failed polls, and say the build may still be running.
   - If you ran `deploy` with `--watch` instead, exit 3 means lost contact with the server, not a failed build. Check `hangar status <id> --json`.
   - Exit 64 is a usage error: fix the arguments.
6. Report.

## Reporting

On success: the build number, the platforms (each `jobs[].action.platform` with its `scheme`), and the TestFlight summary from each job's `outputs`: `testflight.buildID` and `testflight.processingState`. If a job has no TestFlight outputs, say so.

On failure or cancellation:
1. Find the job with `status` `failed` and its failed step (the entry in `steps` with `status` `failed`). Note `failureReason`.
2. Run `hangar logs <job-id> --step <step> --tail 60`.
3. Report the app, build number, platform, failed step, and quote the log lines that show the cause. Do not guess beyond what the log and `failureReason` say.
4. For cancelled builds, say it was cancelled. Do not retry unasked.

## Never

- Never start Xcode Cloud builds.
- Never print, ask for, or echo secret values (tokens, keys, passwords).
- Never run `hangar var set` or `hangar settings` unless the user explicitly asks.
- Never re-deploy after a failure without being asked.

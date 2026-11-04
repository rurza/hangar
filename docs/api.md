# Hangar REST API

The `hangar` CLI and the web UI talk to the server only through this API. Every route lives under `/api/v1` on the server's address (port 8787 by default). Bodies are JSON with camelCase keys; dates are ISO 8601 with milliseconds (`2026-11-04T09:30:00.123Z`). The types named below are the `HangarCore` models.

**No public endpoint returns a secret value.** Variables are write-only: you can set and delete them, and list their names and flags (`VariableSummary`), never their values. A machine's token is returned once, in the response that creates the machine; afterwards only its hash is stored. Error messages name variables but never contain their values.

## Routes

An app's `{id}` is its slug or its UUID. Build and job IDs are UUIDs. A machine's `{id}` is its name or its UUID.

| Method and path | Request | Response |
| --- | --- | --- |
| `GET /health` | | `200` `{"ok": true, "version": "0.1.0"}` |
| `GET /apps` | | `200` `[App]` |
| `POST /apps` | `CreateAppRequest` | `201` `App` |
| `GET /apps/{id}` | | `200` `App` |
| `DELETE /apps/{id}` | | `204`; deletes its builds, jobs, numbers and variables |
| `GET /apps/{id}/variables` | | `200` `[VariableSummary]` |
| `PUT /apps/{id}/variables/{name}` | `VariableInput` | `204` |
| `DELETE /apps/{id}/variables/{name}` | | `204` |
| `GET /variables` | | `200` `[VariableSummary]` (global scope) |
| `PUT /variables/{name}` | `VariableInput` | `204` |
| `DELETE /variables/{name}` | | `204` |
| `GET /apps/{id}/workflow-file` | | `200` `StoredWorkflowFile` `{yaml, workflows, updatedAt}`; `404` `workflow_file_not_found` when the app has none |
| `PUT /apps/{id}/workflow-file` | `PutWorkflowFileRequest` `{yaml}` | `200` `StoredWorkflowFile`; the YAML is parsed first and `400` `invalid_workflow_file` stores nothing (also above 64 KB) |
| `DELETE /apps/{id}/workflow-file` | | `204`; the repository's `.hangar.yml` is used again |
| `GET /apps/{id}/numbers` | | `200` `NumbersReport` |
| `PUT /apps/{id}/numbers/next` | `BumpNumberRequest` | `200` `NumbersReport` |
| `GET /apps/{id}/workflows?ref=` | `ref` required | `200` `WorkflowsResponse` `{commit, workflows: WorkflowFile, source}`; `source` is `hangar` (the stored workflow file wins) or `repository` (`.hangar.yml` at `commit`) |
| `POST /builds` | `DeployRequest` | `202` `Build` with its queued jobs |
| `GET /builds?app=&limit=` | `app` optional (slug or UUID); `limit` defaults to 50, at most 200 | `200` `[Build]`, newest first |
| `GET /builds/{id}` | | `200` `Build` |
| `POST /builds/{id}/cancel` | | `200` `Build` |
| `GET /jobs/{id}` | | `200` `Job` |
| `GET /jobs/{id}/log?step=&tail=` | both optional | `200` `[LogEntry]`: the step's entries, then the last `tail` of them |
| `GET /jobs/{id}/log?follow=1&step=` | | SSE stream, see below |
| `GET /jobs/{id}/artifacts` | | `200` `[ArtifactInfo]` `{name, sizeBytes}`, sorted by name |
| `GET /jobs/{id}/artifacts/{name}` | | `200` the file, `application/octet-stream`, `Content-Disposition: attachment` |
| `GET /machines` | | `200` `[Machine]` with their latest reports; never tokens |
| `POST /machines` | `CreateMachineRequest` | `201` `CreateMachineResponse` `{machine, token}` |
| `DELETE /machines/{id}` | | `204` |
| `GET /settings` | | `200` `SettingsStatus` `{version, appStoreConnect: {keyID, issuerID?, kind}?, githubTokenSet}`; `appStoreConnect` is absent unless `HANGAR_ASC_KEY_ID` and `HANGAR_ASC_KEY_PATH` are set; `kind` is `"team"` when `HANGAR_ASC_ISSUER_ID` is set (non-empty) and `"individual"` otherwise, when `issuerID` is absent; the key and the token are never returned |
| `GET /asc/apps` | | `200` `[ASCAppSummary]` `{id, name, bundleID, registered}` sorted by name, the team's apps from App Store Connect; `registered` is true when a Hangar app already uses that ID; `409` `asc_not_configured` without the key |
| `GET /events` | | SSE stream, see below |

Numbers and deploys ask App Store Connect and Xcode Cloud for the highest known build number. They need the global variables `HANGAR_ASC_KEY_ID` and `HANGAR_ASC_KEY_PATH` (the `.p8` contents), plus `HANGAR_ASC_ISSUER_ID` for a team key; without an issuer ID the key is used as an individual key (JWT `sub: "user"`, no `iss`). The server reads them on every request.

## Worker routes

Worker machines call these routes under `/api/v1/worker`. Each needs `Authorization: Bearer <machine token>`; a missing or unknown token gets `401` `unauthorized`. A `{id}` job must be assigned to the calling machine, else `409` `job_not_assigned_to_machine`.

| Method and path | Request | Response |
| --- | --- | --- |
| `POST /worker/heartbeat` | `HeartbeatRequest` | `200` `HeartbeatResponse`: the IDs of the machine's jobs a user asked to cancel |
| `GET /worker/jobs/next?wait=` | `wait` in seconds, default 25, at most 60 | `200` `JobAssignment` for the oldest job assigned to the machine; `204` when none is assigned within `wait` |
| `POST /worker/jobs/{id}/start` | | `200` `Job`, now `running`; the job must be `assigned` |
| `POST /worker/jobs/{id}/steps` | `StepUpdate` | `200` `Job`; the job must be `running` |
| `POST /worker/jobs/{id}/log` | `LogBatch` | `204`; the job must be `running` |
| `POST /worker/jobs/{id}/artifacts/{name}` | the raw file, streamed | `201` `ArtifactInfo`; the job must be `running` |
| `POST /worker/jobs/{id}/finish` | `JobResult` with `succeeded`, `failed` or `cancelled` | `200` `Job`; the job must be `assigned` or `running` |

A `JobAssignment` carries the job's environment: the global and app variables with their values, an app variable replacing a global one of the same name. It is the only response that holds secret values, and it goes only to the machine the job is assigned to.

## Errors

Every error is a JSON body `{"code": "...", "message": "..."}` with one of these statuses.

| Status | Codes |
| --- | --- |
| `400` | `invalid_request` (malformed body or query), `invalid_job_result`, `invalid_name`, `invalid_variable_name`, `invalid_artifact_name`, `invalid_workflow_file`, `workflow_file_missing`, `approval_not_supported`, `unsupported_repository`, `invalid_path` |
| `401` | `unauthorized` (worker routes) |
| `404` | `not_found` (no such route), `app_not_found`, `build_not_found`, `job_not_found`, `machine_not_found`, `workflow_not_found`, `artifact_not_found`, `ref_not_found` |
| `409` | `app_exists`, `machine_exists`, `bump_not_higher`, `job_not_assigned_to_machine`, `job_state_conflict` (the job is not in a state that allows the call), `asc_not_configured` |
| `502` | `app_store_connect_not_configured`, `build_number_source_unavailable` (the message names the source), `build_number_not_integer`, `source_host_error`, `upstream_unavailable` |
| `500` | `internal_error` |

A deploy that fails with any of these reserves no build number.

## Server-sent events

Both streams answer with `Content-Type: text/event-stream` and `Cache-Control: no-cache`. Each event is one frame, its data a single line of JSON:

```
event: <name>
data: <json>

```

A comment line `: keep-alive` followed by a blank line arrives every 15 seconds; clients ignore it.

### `GET /events`

Every build, job and machine change. The event name is `build`, `job` or `machine`; the data is the `ServerEvent` JSON, which wraps the model: `{"type": "build", "build": {...}}`. The stream ends only when the client disconnects.

### `GET /jobs/{id}/log?follow=1`

1. `event: log` with the stored entries as a `[LogEntry]` array (omitted when there are none).
2. `event: log` with each new batch as it arrives.
3. `event: end` with the finished `Job`, after which the server closes the stream.

A job that has already finished gets its stored entries and `end` straight away. No entry is sent twice or skipped. With `step=`, only that step's entries are sent.

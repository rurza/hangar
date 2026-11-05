# Hangar REST API

The `hangar` CLI and the web UI talk to the server only through this API. Every route lives under `/api/v1` on the server's address (port 8787 by default). Bodies are JSON with camelCase keys; dates are ISO 8601 with milliseconds (`2026-11-04T09:30:00.123Z`). The types named below are the `HangarCore` models.

**No public endpoint returns a secret value.** Variables are write-only: you can set and delete them, and list their names and flags (`VariableSummary`), never their values. A machine's token is returned once, in the response that creates the machine (`POST /machines` or `POST /enroll`); afterwards only its hash is stored. Error messages name variables but never contain their values.

## Request rules

- Every request's `Host` must name the server (see [server setup](server-setup.md#options)): its bound address, its host or MagicDNS name, a `*.ts.net` name or an `--allowed-host`. Any other gets `421` `host_not_allowed`, on every route including the web UI.
- On the public routes (not `/api/v1/worker/*`), every method but `GET`, `HEAD` and `OPTIONS` is refused with `403` `cross_site_request` when `Sec-Fetch-Site` is present and not `same-origin` or `none`, or when `Origin` names another host or port than `Host`. A request body must be sent as `Content-Type: application/json` (parameters such as `charset` are fine), else `415` `unsupported_media_type`; bodiless calls such as `DELETE` or a cancel need no Content-Type. The CLI sends neither `Origin` nor `Sec-Fetch-Site`.

## Routes

An app's `{id}` is its slug or its UUID. Build and job IDs are UUIDs. A machine's `{id}` is its name or its UUID.

| Method and path | Request | Response |
| --- | --- | --- |
| `GET /health` | | `200` `{"ok": true, "version": "0.3.0"}` |
| `GET /apps` | | `200` `[App]`; apps without `iconURL` get one resolved in the background (at most one attempt per app per hour), shown on a later request |
| `POST /apps` | `CreateAppRequest` | `201` `App`; `400` `invalid_input` when `iconURL` is not an https URL with a host; without `iconURL` the server looks for the icon in the background (App Store Connect's newest builds, else the public iTunes lookup) and stores it; the response does not wait |
| `GET /apps/{id}` | | `200` `App` |
| `DELETE /apps/{id}` | | `204`; deletes its builds, jobs, numbers and variables |
| `GET /apps/{id}/variables` | | `200` `[VariableSummary]` |
| `PUT /apps/{id}/variables/{name}` | `VariableInput` | `204` |
| `DELETE /apps/{id}/variables/{name}` | | `204` |
| `GET /variables` | | `200` `[VariableSummary]` (global scope) |
| `PUT /variables/{name}` | `VariableInput` | `204` |
| `DELETE /variables/{name}` | | `204` |
| `GET /apps/{id}/workflow-source` | | `200` `WorkflowSourceStatus` `{stored, repositoryHasWorkflowFile?}`: whether a workflow is defined in Hangar and, without one, whether the repository has a `.hangar.yml` at its default branch (with the app's token). The repository's answer is cached for 10 minutes per app and forgotten when the app's workflow file is stored or deleted; `repositoryHasWorkflowFile` is absent when GitHub could not be asked (not cached) or a workflow is stored (not asked) |
| `GET /apps/{id}/workflow-file` | | `200` `StoredWorkflowFile` `{yaml, workflows, updatedAt}`; `404` `workflow_file_not_found` when the app has none |
| `PUT /apps/{id}/workflow-file` | `PutWorkflowFileRequest` `{yaml}` | `200` `StoredWorkflowFile`; the YAML is parsed first and `400` `invalid_workflow_file` stores nothing (also above 64 KB) |
| `DELETE /apps/{id}/workflow-file` | | `204`; the repository's `.hangar.yml` is used again |
| `GET /apps/{id}/numbers` | | `200` `NumbersReport` |
| `PUT /apps/{id}/numbers/next` | `BumpNumberRequest` | `200` `NumbersReport` |
| `GET /apps/{id}/workflows?ref=` | `ref` optional (the default branch) | `200` `WorkflowsResponse` `{commit, workflows: WorkflowFile, source}`; `source` is `hangar` (the stored workflow file wins) or `repository` (`.hangar.yml` at `commit`) |
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
| `POST /machines/pairings` | | `201` `Pairing` `{code, expiresAt, expiresIn}`: a one-time code (`XXXX-XXXX`, from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`) valid for 15 minutes (`expiresIn` is the seconds left, for a countdown that does not depend on the client's clock); at most 5 are live, a sixth drops the oldest; kept in memory, so a restart forgets them |
| `POST /enroll` | `EnrollRequest` `{code, name, maxConcurrentJobs?}` | `201` `CreateMachineResponse` `{machine, token}`, like `POST /machines` (`maxConcurrentJobs` defaults to 1) and a `machine` event; `403` `invalid_pairing_code` for an unknown, used or expired code; `409` `machine_exists` and `400` `invalid_name` leave the code usable; after 10 failed codes from one address within 10 minutes, that address gets `429` `too_many_attempts` until its oldest failure is 10 minutes old (and after 100 failures from all addresses together, every address does). The code is case-insensitive, its dash optional, and it is compared in constant time. This is the install script's call: curl sends JSON without `Origin`, so the cross-site rules let it through |
| `DELETE /machines/{id}` | | `204` |
| `GET /settings` | | `200` `SettingsStatus` `{version, appStoreConnect: {keyID, issuerID?, kind}?, githubTokenSet}`; `appStoreConnect` is absent unless `HANGAR_ASC_KEY_ID` and `HANGAR_ASC_KEY_PATH` are set; `kind` is `"team"` when `HANGAR_ASC_ISSUER_ID` is set (non-empty) and `"individual"` otherwise, when `issuerID` is absent; the key and the token are never returned; `workerInstallAvailable` is true when the server has a `hangar-worker` to hand out at `GET /install/hangar-worker`; `github` is `GitHubStatus` `{login?, source: "token"|"gh"}` when a token is set (`login` from GitHub's `GET /user`, cached 5 minutes per token; absent when GitHub cannot be asked) |
| `POST /settings/asc-key` | `SaveASCKeyRequest` `{keyID, issuerID?, privateKey}` | `200` `ASCKeyTestResult` `{kind, keyID, appCount}`. Tests the key first (lists the key's apps in App Store Connect) and only then stores `HANGAR_ASC_KEY_PATH` (secret, as a file), `HANGAR_ASC_ISSUER_ID` (deleted without one) and `HANGAR_ASC_KEY_ID`. `409` `issuer_required` when App Store Connect refuses a key sent without an issuer ID; `400` `asc_key_rejected` when it refuses one with an issuer ID, `asc_key_forbidden` on 403 (no role that can list apps), `invalid_asc_key` when the text is not a .p8 key; `502` `asc_unavailable` |
| `POST /settings/github-token` | `SaveGitHubTokenRequest` `{token}` | `200` `GitHubLoginResponse` `{login}`. Checks the token with GitHub's `GET /user` and only then stores it as the global `HANGAR_GITHUB_TOKEN` (secret). `400` `github_token_rejected` on 401, `invalid_token` for an empty token |
| `GET /setup` | | `200` `SetupStatus` `{appStoreConnect?, github?, machines, apps, localWorker, localHostName?, workerInstallAvailable}` for the first-run setup page. `localWorker`: a machine named like this Mac's `LocalHostName` (case-insensitive) exists. `viewerIsLocal`: the request's socket peer is this Mac (see below). `installedWorker` `{serverURL?, agentLoaded}` (only for a local viewer): a worker configuration exists or the `app.hangar.worker` launchd agent is loaded for the server's user |
| `GET /setup/asc-keys` | | Local only. `200` `[FoundASCKey]` `{keyID, path, displayPath, modifiedAt}`, newest first: files named `AuthKey_<KEYID>.p8` (8–12 uppercase letters and digits, at most 16 KB; in `~/Downloads` also a browser's `AuthKey_<KEYID> (1).p8`; symbolic links are skipped) in `$API_PRIVATE_KEYS_DIR`, `./private_keys` (the server's working directory), `~/private_keys`, `~/.private_keys`, `~/.appstoreconnect/private_keys` and `~/Downloads` of the user the server runs as. Contents are never returned |
| `POST /setup/asc-keys/use` | `UseASCKeyRequest` `{path, issuerID?}` | Local only. As `POST /settings/asc-key`, with the key read from `path`, which must be one the scan finds at that moment (else `400` `asc_key_not_found`); the key ID comes from the file name |
| `GET /setup/github` | | Local only. `200` `GitHubCLIStatus` `{ghLogin?}`: the login of the GitHub CLI's active github.com account (`gh api user --jq .login`, with Homebrew's directories on `PATH`, 15 s at most) |
| `POST /setup/github/use-gh` | | Local only. `200` `GitHubLoginResponse` `{login}`. Copies `gh auth token --hostname github.com` into `HANGAR_GITHUB_TOKEN` after checking it as `POST /settings/github-token` does; the token never appears in a response, a command line or a log. `400` `gh_not_signed_in` without a gh login. `GitHubStatus.source` is `gh` while the stored token is the one copied |
| `POST /setup/local-worker` | | Local only. `202` `LocalWorkerInstall` `{state: running, lines}`. Installs and enrolls the worker on the server's own Mac for the server's user: creates a pairing code and runs the `GET /install` script for `http://<bound address>:<port>` (loopback when bound to every interface) with `HANGAR_PAIRING_CODE`, `HANGAR_MACHINE_NAME` (`LocalHostName`) and `HANGAR_BIN_DIR` (`~/.local/bin` unless the server's environment sets it); of the server's environment only `HOME`, `PATH`, `USER`, `LOGNAME`, `TMPDIR`, `LANG`, `SHELL`, `HANGAR_BIN_DIR`, `HANGAR_WORKER_CONFIG` and `HANGAR_NO_LAUNCHD` reach the script. One install at a time: a second call returns the running one; an install still running after 10 minutes is stopped and fails, and one that exits 0 without enrolling this Mac fails too. `409` `machine_exists` when this Mac is enrolled, `409` `worker_already_installed` when a worker is already set up here (its configuration exists, or its launchd agent is loaded; not asked under `HANGAR_NO_LAUNCHD=1`): the install never replaces or restarts it. `503` `worker_binary_missing`, `host_name_unknown`, `server_address_unusable` (`--port 0`) |
| `GET /setup/local-worker` | | Local only. `200` `LocalWorkerInstall` `{state: running|succeeded|failed, lines, machine?, message?}`: the last install since the server started (its last 200 output lines; `machine` once enrolled, `message` when it failed); `404` `not_found` when none ran |
| `GET /asc/apps` | | `200` `[ASCAppSummary]` `{id, name, bundleID, registered, iconURL?}` sorted by name, the team's apps from App Store Connect; `registered` is true when a Hangar app already uses that ID; `iconURL` (https, 512 px) is absent when no icon was found (each source is given up after 5 s); `409` `asc_not_configured` without the key |
| `GET /github/repos` | | `200` `[GitHubRepo]` `{fullName, htmlURL, isPrivate, defaultBranch, description?, pushedAt?, archived}`: every repository the global `HANGAR_GITHUB_TOKEN` can see (`GET /user/repos`, owner, collaborator and organization member; at most 10 pages of 100), most recently pushed first; cached in memory for 5 minutes per token, so a new token is never served the old token's list; `409` `github_not_configured` without a token; `502` `github_unauthorized` when GitHub refuses it |
| `GET /github/repos/{owner}/{repo}/inspect?ref=` | `ref` optional (the default branch) | `200` `RepositoryInspection` `{commit, apps: [DetectedApp], projects, notes, hasWorkflowFile, appStoreConnectUnavailable, appStoreConnectError?}`, read with the global token (none for a public repository) before the app exists in Hangar. A `DetectedApp` `{name, bundleIDs, platforms, schemes: [DetectedScheme], icon: DetectedIcon?, appStoreConnect: ASCAppSummary?}` is one or more application targets that share a bundle ID (`PRODUCT_BUNDLE_IDENTIFIER` from XcodeGen's `project.yml`, or `bundleIdPrefix` and the target's name, else `project.pbxproj`; a bundle ID built from settings the file does not set is left out); apps no scheme builds (an embedded helper) are dropped. Without `ref`, `404` `repository_not_found` when GitHub has no such repository for the token. With the App Store Connect key, each app is matched by bundle ID (`GET /v1/apps?filter[bundleId]=`) and takes its App Store Connect name; matched apps come first. When App Store Connect is configured but fails, `appStoreConnectUnavailable` is true, `appStoreConnectError` says why (never its response text), and no app is matched. `hasWorkflowFile`: the repository has its own `.hangar.yml`. Trees and files read at a commit are cached for 10 minutes per repository, commit and token, so a `workflow-suggestion` right after reads nothing again. Files over 8 MB are not read (a note says so). `projects` lists every workspace and project, the chosen one first. Errors as for `workflow-suggestion` |
| `GET /github/repos/{owner}/{repo}/icon?commit=&path=` | `commit` a SHA; `path` an image inside an `.appiconset` | `200` the PNG or JPEG bytes (at most 5 MB, checked against `Content-Length` first), cached for an hour; `400` `invalid_path` for any other path; `404` `icon_not_found` when it is not a PNG or JPEG |
| `GET /apps/{id}/workflow-suggestion?ref=&bundleID=` | both optional; `ref` defaults to the default branch | `200` `WorkflowSuggestion` `{commit, yaml, notes, workflows: WorkflowFile, schemes: [DetectedScheme], icon: DetectedIcon?, hasWorkflowFile}`: a `release` workflow worked out from the repository (with the app's token, as `.hangar.yml` reads): the top-most workspace (not one inside a project, nor deeper than the top-most project), else project, else the project XcodeGen's `project.yml` generates; shared schemes (else XcodeGen's, else the application targets), each scheme's platform from XcodeGen or the target's `SDKROOT`; the team; the highest Xcode version online machines report; `tools` (`xcodegen`, and `brew` when `ci_scripts` use it); export `app-store-connect` and no post-actions. When the repository builds several apps, only the schemes of the app with `bundleID` (else this app's bundle ID from App Store Connect, `GET /v1/apps/{id}`) are archived; without either, every app's are, with a note. `yaml` parses to `workflows`; `notes` say what was guessed. `schemes` lists every scheme found, sorted. `icon` is the first app's: the largest image of its `.appiconset` (`kind: "appiconset"`) or an Icon Composer `.icon` bundle (`kind: "iconcomposer"`, which only a build can render). `Pods`, `Carthage`, `.build`, `DerivedData` and `node_modules` are skipped. Nothing is stored. `422` `no_project_found`; `504` `detection_timeout` after 15 s; `404` `ref_not_found` |
| `GET /apps/{id}/repo-icon?ref=` | `ref` optional | `200` the image of the `appiconset` icon `workflow-suggestion` finds, cached in memory for an hour; `404` `icon_not_found` when there is none (or only an Icon Composer icon) |
| `GET /events` | | SSE stream, see below |

### Jobs

A `Job`'s `action` is the workflow action it runs: `{kind: "archive", scheme, platform, export}` or `{kind: "test", scheme, platform, destination?, testPlan?}` (an action without `kind`, stored before test actions existed, is an archive). A deploy creates one job per action of either kind; they share the build's number. A test job's `steps` are `checkout`, `post-clone`, `pre-xcodebuild`, `test`, `post-xcodebuild`, `upload-artifacts` and `cleanup`.

#### Test outputs

Once its result bundle is read, a test job's `outputs` hold, as strings: `test.passed`, `test.failed`, `test.skipped`, `test.total`, and `test.failures`, a JSON array of `{name, message}` (one per failing test, its first failure message; at most 50, secrets masked). A `Machine`'s report lists `simulatorRuntimes` (`["iOS 27.2", "visionOS 27.1"]`); the scheduler does not give a simulator test to a machine without a runtime for its platform.

Numbers and deploys ask App Store Connect and Xcode Cloud for the highest known build number. They need the global variables `HANGAR_ASC_KEY_ID` and `HANGAR_ASC_KEY_PATH` (the `.p8` contents), plus `HANGAR_ASC_ISSUER_ID` for a team key; without an issuer ID the key is used as an individual key (JWT `sub: "user"`, no `iss`). The server reads them on every request.

**Local only:** the routes marked so act on the server's own Mac (its key files, its GitHub CLI login, installing a worker there), so they answer only requests whose socket peer is this Mac: loopback, the bound address or one of its interface addresses (a browser on this Mac that opens the tailnet name counts). Headers are never trusted for this. Any other peer gets `403` `local_only`.

## Install routes

These live outside `/api/v1`. They are `GET`s, so the cross-site rules do not apply, but the `Host` check does.

| Method and path | Response |
| --- | --- |
| `GET /install` | `200` `text/plain; charset=utf-8`: the worker install script, run as `curl -fsSL http://<server>:8787/install \| sh` against the server's own address and port (not a `tailscale serve` HTTPS proxy: the script uses the address it was fetched from, always over `http://`). The server's address in it is `http://<Host>`, taken from the request's (already allowed) `Host`; a `Host` that is not a plain DNS name or IP address with a valid port gets `400` `invalid_request`. See [worker setup](worker-setup.md) |
| `GET /install/hangar-worker` | `200` the `hangar-worker` binary next to `hangar-server` (symlinks resolved), `application/octet-stream` with `Content-Length` and `X-Hangar-Version`; `503` `worker_binary_missing` when there is none (install-server.sh installs it, universal: Apple silicon and Intel) |

## Worker routes

Worker machines call these routes under `/api/v1/worker`. Each needs `Authorization: Bearer <machine token>`; a missing or unknown token gets `401` `unauthorized`. A `{id}` job must be assigned to the calling machine, else `409` `job_not_assigned_to_machine`.

| Method and path | Request | Response |
| --- | --- | --- |
| `GET /worker/me` | | `200` `Machine`: the machine the token belongs to (never the token); `hangar-worker check` uses it |
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
| `400` | `invalid_request` (malformed body or query), `asc_key_not_found`, `asc_key_rejected`, `asc_key_forbidden`, `invalid_asc_key`, `invalid_key_id`, `github_token_rejected`, `invalid_token`, `gh_not_signed_in`, `invalid_job_result`, `invalid_name`, `invalid_variable_name`, `invalid_artifact_name`, `invalid_workflow_file`, `workflow_file_missing`, `approval_not_supported`, `unsupported_repository`, `invalid_path` |
| `401` | `unauthorized` (worker routes) |
| `403` | `cross_site_request`, `invalid_pairing_code`, `local_only` |
| `404` | `not_found` (no such route), `app_not_found`, `build_not_found`, `job_not_found`, `machine_not_found`, `workflow_not_found`, `artifact_not_found`, `ref_not_found`, `icon_not_found`, `repository_not_found` (no such repository, or the token cannot read it) |
| `409` | `app_exists`, `machine_exists`, `bump_not_higher`, `job_not_assigned_to_machine`, `job_state_conflict` (the job is not in a state that allows the call), `asc_not_configured`, `github_not_configured`, `issuer_required` (the App Store Connect key needs its issuer ID), `worker_already_installed` |
| `415` | `unsupported_media_type` |
| `422` | `no_project_found` (no Xcode project in the repository) |
| `421` | `host_not_allowed` |
| `429` | `too_many_attempts` (`POST /enroll`) |
| `502` | `app_store_connect_not_configured`, `build_number_source_unavailable` (the message names the source), `build_number_not_integer`, `source_host_error` (also a GitHub response Hangar cannot read), `file_too_large`, `github_unauthorized` (GitHub refused the token; the message says whether it was the app's own `HANGAR_GITHUB_TOKEN`), `upstream_unavailable`, `asc_unavailable` |
| `500` | `internal_error` |
| `503` | `worker_binary_missing` (`GET /install/hangar-worker`, `POST /setup/local-worker`), `host_name_unknown`, `server_address_unusable`, `github_rate_limited` (the message says when to try again; `Retry-After` gives the seconds) |
| `504` | `detection_timeout` (GitHub did not answer within 15 s) |

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

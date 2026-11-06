# Hangar REST API

The `hangar` CLI and the web UI talk to the server only through this API. Every route lives under `/api/v1` on the server's address (port 8787 by default). Bodies are JSON with camelCase keys; dates are ISO 8601 with milliseconds (`2026-11-04T09:30:00.123Z`). The types named below are the `HangarCore` models.

**No public endpoint returns a secret value.** Variables are write-only: you can set and delete them, and list their names and flags (`VariableSummary`), never their values. A machine's token is returned once, in the response that creates the machine (`POST /machines` or `POST /enroll`); afterwards only its hash is stored. The same holds for a job token (`POST /worker/jobs/{id}/token`). Error messages name variables but never contain their values.

## Request rules

- Every request's `Host` must name the server (see [server setup](server-setup.md#options)): its bound address, its host names, its own MagicDNS name (and that name's first label) or an `--allowed-host`. Other `*.ts.net` names are refused. Any other gets `421` `host_not_allowed`, on every route including the web UI.
- On the public routes (not `/api/v1/worker/*`), every method but `GET`, `HEAD` and `OPTIONS` is refused with `403` `cross_site_request` when `Sec-Fetch-Site` is present and not `same-origin` or `none`, or when `Origin` names another host or port than `Host`. A request body must be sent as `Content-Type: application/json` (parameters such as `charset` are fine), else `415` `unsupported_media_type`; bodiless calls such as `DELETE` or a cancel need no Content-Type. The CLI sends neither `Origin` nor `Sec-Fetch-Site`.

## Who may call the API

Every public route (everything under `/api/v1` but the worker routes) needs one of:

- **The owner's device.** A request without an API token is let in when its socket peer is a tailnet device whose Tailscale login is one of the owner logins. The server asks the local Tailscale daemon (`tailscale whois`, its LocalAPI) and caches the answer for a minute (10 seconds for an unknown address). By default the owner is the login that owns the server's own tailnet node; `PUT /access`, Settings › Access or `hangar-server access allow <login>…` replace that list. Only the socket address counts, never a header. Tailscale names a device, not a process, so a connection from the server Mac's own address counts only when a process of the server's own macOS user holds its client end (found with `libproc`; a build running as `hangar` there is refused). Never the owner: loopback and LAN addresses (host-executor builds and local agents connect from there), a request a proxy relayed (it carries `Forwarded`, `X-Forwarded-*`, `X-Real-IP` or `Tailscale-User-Login`), a tagged device, another tailnet user, and anyone while Tailscale is not running.
- **An API token**, `Authorization: Bearer hgr_…`, from anywhere.

Anything else gets `401` `authentication_required`. Open to all: `GET /health`, and `POST /enroll`, which a pairing code authenticates (the `curl … | sh` install). The web UI's pages and the install routes are static and open; the data they show comes from the API. The worker routes keep their machine and job tokens.

### API tokens

A token is created in Settings › Agent Access or with `hangar tokens create` (by the owner), or on the server Mac with `hangar-server token create`. It is shown once, stored only as its SHA-256, and revoked by deleting it.

- An unknown or revoked token gets `401` `invalid_api_token`; it never falls back to the owner check. A bearer value that does not start with `hgr_` (a machine token, say) is ignored on the public routes.
- Each token has a scope, and scopes nest: `read` < `deploy` < `configure` < `owner`. A route outside the token's scope gets `403` `token_scope`.
  - `read`: every `GET` but the local-only `/setup/*` routes, `/access` and `/api-tokens` (except `/api-tokens/current`).
  - `deploy`: also `POST /builds` and `POST /builds/{id}/cancel`. A token's deploy builds only a branch or tag of the app's own repository: the ref is looked up as `heads/<ref>`, then `tags/<ref>`, so a commit SHA (which may exist only in a fork) or `pull/N/head` gets `400` `ref_not_allowed`. The owner deploys any ref.
  - `configure`: also `DELETE /apps/{id}`, `PUT` and `DELETE /apps/{id}/workflow-file`, `POST /apps/{id}/beta-groups` and `PUT /apps/{id}/numbers/next`. Not `POST /apps`: adding an app picks the repository whose scripts get the secrets, so only the owner adds apps.
  - `owner`: everything the owner can do. Only `hangar-server token create --scope owner`, run on the server Mac against the data directory, makes one; `POST /api-tokens` refuses the scope with `400` `invalid_scope`. It is for the owner's own CLI where Tailscale cannot vouch for it (loopback, a tagged server node). `hangar mcp` refuses it.
  - No other token may change variables, variable groups or their links, settings or access, create, renew, import or remove the signing certificate (`GET /signing` is `read`), run setup, add apps, add, pair, pause, resume, allow VM builds on or delete machines, or create, list or revoke tokens.
- Neither a token nor the owner's device excuses a cross-site request: the cross-site rules run first.
- Every request a token makes other than a `GET` is logged with the token's name. `lastUsedAt` is updated at most once a minute.

### Getting a token

- **The CLI** sends a token when it finds one: `HANGAR_API_TOKEN`, else the file named by `HANGAR_API_TOKEN_FILE`, else `~/.config/hangar/token` (`$XDG_CONFIG_HOME/hangar/token`). No command takes a token as an argument. From one of the owner's tailnet devices, with `HANGAR_SERVER` set to the server's tailnet address or name, it needs none.
- **On the server Mac, without the API** (Tailscale down, a login change, the CLI on loopback): as the user the server runs as,

  ```sh
  (umask 077; mkdir -p ~/.config/hangar; hangar-server token create my-cli --scope owner > ~/.config/hangar/token)
  ```

  prints the secret to stdout only. `hangar-server access show`, `allow <login>…` and `reset` read and set the owner logins the same way. Both take `--data-dir` (default `$HANGAR_DATA_DIR`, else `~/Library/Application Support/Hangar/server`) and work whether the server runs or not.
- **Agents**: see [MCP](mcp.md#setup). Keep the token in a file, never on a command line.

## Routes

An app's `{id}` is its slug or its UUID. Build and job IDs are UUIDs. A machine's `{id}` is its name or its UUID.

| Method and path | Request | Response |
| --- | --- | --- |
| `GET /health` | | `200` `{"ok": true, "version": "0.14.0"}` |
| `GET /apps` | | `200` `[App]`; apps without `iconURL` get one resolved in the background (at most one attempt per app per hour), shown on a later request |
| `POST /apps` | `CreateAppRequest` | `201` `App`. Owner only. `400` `invalid_repository` unless `repoURL` is a GitHub repository (`https://github.com/<owner>/<repo>` or `git@github.com:…`); `400` `invalid_input` when `iconURL` is not an https URL with a host (the web UI shows icons only from `*.mzstatic.com` and the server itself); without `iconURL` the server looks for the icon in the background (App Store Connect's newest builds, else the public iTunes lookup) and stores it; the response does not wait |
| `GET /apps/{id}` | | `200` `App` |
| `DELETE /apps/{id}` | | `204`; deletes its builds, jobs, numbers and variables |
| `GET /apps/{id}/variables` | | `200` `[VariableSummary]`, by name; `workflows` lists the workflows a variable is limited to (empty: all workflows) |
| `PUT /apps/{id}/variables/{name}` | `VariableInput` `{value, isSecret, asFile, workflows}` | `204`. Sets the variable limited to exactly `workflows` (empty or absent: the one for all workflows), replacing that one. One name may exist once for all workflows and any number of times for disjoint sets of workflows: a set sharing a workflow with another is `409` `variable_workflows_overlap`. `HANGAR_*` names cannot be limited (`400` `reserved_variable`); an empty or overlong workflow name is `400` `invalid_workflows` |
| `PATCH /apps/{id}/variables/{name}?workflow=` | `VariableUpdate` `{workflows?, value?, isSecret?, asFile?}` | `204`. Changes the variable limited to exactly the `workflow` parameters (repeat it per workflow; none: the one for all workflows); what is absent stays. `isSecret: false` on a secret needs `value` too, else `400` `value_required`: a secret is made plain only by someone who knows it. `404` `variable_not_found`; moving it onto workflows another covers is `409` `variable_workflows_overlap`, or `variable_exists` for all workflows |
| `DELETE /apps/{id}/variables/{name}?workflow=` | | `204`; deletes the variable limited to exactly the `workflow` parameters (none: the one for all workflows) |
| `GET /apps/{id}/environment?workflow=` | | `200` `[EffectiveVariable]` `{name, isSecret, asFile, source: {kind, group?, workflows}, replaces}`: what a job of `workflow` gets, by name, with no values. Without `workflow` only what applies to every workflow. A job gets each name from the first of: an app variable limited to its workflow, the app's for all workflows, a group linked for its workflow, a group linked for all workflows, a global variable (a global secret only if the app receives it, see `/apps/{id}/global-secrets`); between two groups at the same level the one linked first. `replaces` lists the lower ones that define the name too |
| `GET /apps/{id}/variable-groups` | | `200` `[AppVariableGroupLink]` `{groupID, name, workflows, variables}`, in precedence order (first linked first) |
| `PUT /apps/{id}/variable-groups/{group}` | `LinkVariableGroupRequest` `{workflows}` | `204`; links the group for `workflows` (empty: all), or changes the workflows of its link, which keeps its place. `{group}` is the group's UUID or name. `404` `variable_group_not_found` |
| `DELETE /apps/{id}/variable-groups/{group}` | | `204`; unlinks it |
| `GET /apps/{id}/global-secrets` | | `200` `AppGlobalSecrets` `{secrets: [{name, asFile, granted}], gitHubToken: "app"|"global"|"none"}`: every global secret variable (the reserved `HANGAR_*` ones aside), by name, and whether this app's jobs get it; and where its jobs' `HANGAR_GITHUB_TOKEN` comes from (`app`: its own variable; `global`: the one in Settings, which the UI warns about). No values |
| `PUT /apps/{id}/global-secrets/{name}` | | `204`; the app's jobs get the global secret `name`. `404` `variable_not_found` when there is no such global secret (a plain or `HANGAR_*` one included). No API token may call it |
| `DELETE /apps/{id}/global-secrets/{name}` | | `204`; they stop getting it. No API token may call it |
| `GET /variable-groups` | | `200` `[VariableGroup]` `{id, name, createdAt, variables, apps: [{appID, slug, name, workflows}]}`, by name |
| `POST /variable-groups` | `VariableGroupRequest` `{name}` | `201` `VariableGroup`. `400` `invalid_name` (empty, over 64 characters or several lines), `409` `variable_group_exists` (names are unique ignoring case) |
| `GET /variable-groups/{group}` | | `200` `VariableGroup`; `{group}` is the UUID or name |
| `PATCH /variable-groups/{group}` | `VariableGroupRequest` `{name}` | `200` `VariableGroup`, renamed |
| `DELETE /variable-groups/{group}` | | `204`; deletes it with its variables and every app's link to it |
| `GET /variable-groups/{group}/variables` | | `200` `[VariableSummary]` |
| `PUT /variable-groups/{group}/variables/{name}` | `VariableInput` | `204`; `workflows` must be empty (a group is limited through its links), and `HANGAR_*` names are refused (`400` `reserved_variable`) |
| `DELETE /variable-groups/{group}/variables/{name}` | | `204` |
| `GET /variables` | | `200` `[VariableSummary]` (global scope) |
| `PUT /variables/{name}` | `VariableInput` | `204`. A new global secret reaches no app until an app receives it; a plain global that becomes secret keeps reaching every app that had it (all of them). The old App Store Connect names `HANGAR_ASC_*` are refused at every scope (`400` `reserved_variable`): the key is a setting |
| `DELETE /variables/{name}` | | `204`; a global secret's grants go with it |
| `GET /apps/{id}/workflow-source?repository=` | `repository=1` asks the repository even when a workflow is stored | `200` `WorkflowSourceStatus` `{stored, repositoryHasWorkflowFile?}`: whether a workflow is defined in Hangar and, without one, whether the repository has a `.hangar.yml` at its default branch (with the app's token). The repository's answer is cached for 10 minutes per app and forgotten when the app's workflow file is stored or deleted; `repositoryHasWorkflowFile` is absent when GitHub could not be asked (not cached), or when a workflow is stored and `repository=1` was not passed (not asked); with `repository=1` the repository is asked (and cached) whether or not a workflow is stored, and `stored` still says which wins |
| `GET /apps/{id}/workflow-file` | | `200` `StoredWorkflowFile` `{yaml, workflows, updatedAt}`; `404` `workflow_file_not_found` when the app has none |
| `PUT /apps/{id}/workflow-file` | `PutWorkflowFileRequest` `{yaml}` | `200` `StoredWorkflowFile`; the YAML is parsed first and `400` `invalid_workflow_file` stores nothing (also above 64 KB) |
| `DELETE /apps/{id}/workflow-file` | | `204`; the repository's `.hangar.yml` is used again |
| `GET /apps/{id}/numbers` | | `200` `NumbersReport` |
| `PUT /apps/{id}/numbers/next` | `BumpNumberRequest` | `200` `NumbersReport` |
| `GET /apps/{id}/branches` | | `200` `RepositoryBranches` `{defaultBranch?, branches}`: the repository's branches (at most 100) with the app's token, the default branch first; for the Deploy sheet's branch picker, which still takes a typed tag or SHA. Cached for a minute per app; a failure is not cached (`502` `github_unauthorized` when GitHub refuses the token) |
| `GET /apps/{id}/workflows?ref=` | `ref` optional (the default branch) | `200` `WorkflowsResponse` `{commit, workflows: WorkflowFile, source}`; `source` is `hangar` (the stored workflow file wins) or `repository` (`.hangar.yml` at `commit`) |
| `GET /apps/{id}/deploy-check?workflow=&ref=&commit=&machine=` | `workflow` required; `ref` optional (the default branch); `commit` optional (a SHA, e.g. the one `/workflows` returned: the ref is then not resolved, and the repository's `.hangar.yml` is read once per commit and cached for 10 minutes, so repeated checks make no GitHub calls; `400` `invalid_request` when not 7–40 hex digits); `machine` optional (name or UUID: judge only that machine, as a pinned deploy) | `200` `DeployCheck` `{canDeploy, blocking: [{action, reasons}], warnings: [{action, reasons}], machines: [{id, name, online, problems, waits, paused}]}`: a dry run of a deploy. Reads the workflow exactly as `POST /builds` does (the stored one, else `.hangar.yml` at the ref) and judges each action's job with the scheduler's own rules against every machine as a scheduler tick sees it, online by the server's clock. `action` is labelled like `Archive – macOS · Legilo`; `reasons` maps machine name to the scheduler's reasons. Offline, Xcode, tools, signing, a missing simulator runtime and an outdated worker block (`blocking`; `canDeploy` false); busy, low disk and a paused machine (`builds paused`) only delay (`warnings`): the build queues and waits, also when it is pinned to a paused Mac. A machine's `problems` are its blocking reasons over all actions and `waits` its delaying ones; `paused` says builds are turned off on it. `notices: [{code, message}]` never block: `undefined-variables` (a `ci_scripts/*.sh` reads `$NAME`/`${NAME}` that no Hangar variable this workflow gets, `CI_*` name or standard variable defines and no script assigns; a name set only for other workflows says which), `unknown-workflow-names` (an app variable or a group link is limited to a workflow name the workflow file does not have), `script-not-executable` (a hook without mode 100755) and `beta-app-description-missing` (a TestFlight step submits for external review and App Store Connect has no Beta App Description); the scripts are read once per commit, App Store Connect asked once per 5 minutes per app, and a lookup that fails gives no notice. Reserves no number and creates nothing. Errors as for `POST /builds` (`workflow_not_found`, `ref_not_found`, `machine_not_found`, …) |
| `POST /builds` | `DeployRequest` | `202` `Build` with its queued jobs |
| `GET /builds?app=&limit=` | `app` optional (slug or UUID); `limit` defaults to 50, at most 200 | `200` `[Build]`, newest first |
| `GET /builds/{id}` | | `200` `Build` |
| `POST /builds/{id}/cancel` | | `200` `Build` |
| `GET /jobs/{id}` | | `200` `Job` |
| `GET /jobs/{id}/log?step=&tail=` | both optional | `200` `[LogEntry]`: the step's entries, then the last `tail` of them |
| `GET /jobs/{id}/log?format=text&step=&tail=` | | `200` `text/plain` attachment, one `<time> [<step>] <line>` per entry |
| `GET /jobs/{id}/log?follow=1&step=` | | SSE stream, see below |
| `GET /jobs/{id}/artifacts` | | `200` `[ArtifactInfo]` `{name, sizeBytes}`, sorted by name |
| `GET /jobs/{id}/artifacts/{name}` | | `200` the file, `application/octet-stream`, `Content-Disposition: attachment` |
| `GET /machines` | | `200` `[Machine]` with their latest reports; never tokens |
| `POST /machines` | `CreateMachineRequest` | `201` `CreateMachineResponse` `{machine, token}`. Owner only; a new Mac normally enrolls with a pairing code instead (`POST /enroll`) |
| `POST /machines/pairings` | | `201` `Pairing` `{code, expiresAt, expiresIn}`: a one-time code (`XXXX-XXXX`, from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`) valid for 15 minutes (`expiresIn` is the seconds left, for a countdown that does not depend on the client's clock); at most 5 are live, a sixth drops the oldest; kept in memory, so a restart forgets them |
| `POST /enroll` | `EnrollRequest` `{code, name, maxConcurrentJobs?}` | `201` `CreateMachineResponse` `{machine, token}`, like `POST /machines` (`maxConcurrentJobs` defaults to 1) and a `machine` event; `403` `invalid_pairing_code` for an unknown, used or expired code; `409` `machine_exists` and `400` `invalid_name` leave the code usable; after 10 failed codes from one address within 10 minutes, that address gets `429` `too_many_attempts` until its oldest failure is 10 minutes old (and after 100 failures from all addresses together, every address does). The code is case-insensitive, its dash optional, and it is compared in constant time. This is the install script's call: curl sends JSON without `Origin`, so the cross-site rules let it through |
| `POST /machines/{id}/pause` | | `200` `Machine` with `paused: true`, and a `machine` event: builds are turned off on that Mac. The scheduler gives it no new jobs; a job it was already given or is running finishes, and the worker keeps reporting (so it stays online) and updating itself. Jobs that could run only there wait in the queue (reason `builds paused`) rather than fail. `{id}` is the name or UUID; `404` `machine_not_found` |
| `POST /machines/{id}/resume` | | `200` `Machine` with `paused: false`, and a `machine` event; the scheduler ticks at once, so waiting jobs can start. `404` `machine_not_found` |
| `POST /machines/{id}/vm-builds` | | `200` `Machine` with `vmBuilds: true`, and a `machine` event: the owner allows VM builds on that Mac. Only such a machine is given VM jobs and the server's signing identity; one whose report has `vm` but is not allowed waits with the queue note "the owner has not allowed VM builds on this Mac". A heartbeat cannot set it. Owner only |
| `DELETE /machines/{id}/vm-builds` | | `200` `Machine` with `vmBuilds: false`: VM builds stop on that Mac (a running job finishes). Owner only |
| `DELETE /machines/{id}` | | `204` |
| `GET /settings` | | `200` `SettingsStatus` `{version, appStoreConnect: {keyID, issuerID?, kind}?, githubTokenSet, developmentKey?}`; `appStoreConnect` is absent unless the server holds an App Store Connect key (a setting, never a variable); `kind` is `"team"` with an issuer ID and `"individual"` without, when `issuerID` is absent; `developmentKey` is the optional development key, the same shape; the key and the token are never returned; `workerInstallAvailable` is true when the server has a `hangar-worker` to hand out at `GET /install/hangar-worker`; `github` is `GitHubStatus` `{login?, source: "token"|"gh"}` when a token is set (`login` from GitHub's `GET /user`, cached 5 minutes per token; absent when GitHub cannot be asked) |
| `POST /settings/asc-key` | `SaveASCKeyRequest` `{keyID, issuerID?, privateKey}` | `200` `ASCKeyTestResult` `{kind, keyID, appCount}`. Tests the key first (lists the key's apps in App Store Connect) and only then stores it as the server's key, sealed with the master key. It is a setting: no job's environment ever has it, and only `JobAssignment.appStoreConnectKey` carries it (see *Worker routes*). `409` `issuer_required` when App Store Connect refuses a key sent without an issuer ID; `400` `asc_key_rejected` when it refuses one with an issuer ID, `asc_key_forbidden` on 403 (no role that can list apps), `invalid_asc_key` when the text is not a .p8 key; `502` `asc_unavailable` |
| `POST /settings/development-key` | `SaveASCKeyRequest` `{keyID, issuerID, privateKey}` | `200` `ASCKeyTestResult` `{kind: "team", keyID, appCount}` (`appCount` is the number of bundle IDs it reads). The optional development key: a second team key, with the Developer role and access to Certificates, Identifiers & Profiles, that a VM archive's guest gets only when the server could not provide one of its development profiles. Refused: without an issuer ID (`400` `team_key_required`), the server's own key (`400` `development_key_is_main_key`), a key that can list the team's users, i.e. an Admin key (`400` `development_key_too_powerful`), one App Store Connect rejects (`asc_key_rejected`) or that cannot read identifiers (`asc_key_forbidden`). No API token may call it |
| `DELETE /settings/development-key` | | `204`; removes the stored copy (it stays valid at Apple until revoked there). No API token may call it |
| `POST /settings/github-token` | `SaveGitHubTokenRequest` `{token}` | `200` `GitHubLoginResponse` `{login}`. Checks the token with GitHub's `GET /user` and only then stores it as the global `HANGAR_GITHUB_TOKEN` (secret). `400` `github_token_rejected` on 401, `invalid_token` for an empty token |
| `GET /setup` | | `200` `SetupStatus` `{appStoreConnect?, github?, machines, apps, localWorker, localHostName?, workerInstallAvailable}` for the first-run setup page. `localWorker`: a machine named like this Mac's `LocalHostName` (case-insensitive) exists. `viewerIsLocal`: the request's socket peer is this Mac (see below). `installedWorker` `{serverURL?, agentLoaded}` (only for a local viewer): a worker configuration exists or the `app.hangar.worker` launchd agent is loaded for the server's user. `dedicatedUserRequired`: the server does not run as the macOS user `hangar`, so `POST /setup/local-worker` is refused |
| `GET /setup/asc-keys` | | Local only. `200` `[FoundASCKey]` `{keyID, path, displayPath, modifiedAt}`, newest first: files named `AuthKey_<KEYID>.p8` (8–12 uppercase letters and digits, at most 16 KB; in `~/Downloads` also a browser's `AuthKey_<KEYID> (1).p8`; symbolic links are skipped) in `$API_PRIVATE_KEYS_DIR`, `./private_keys` (the server's working directory), `~/private_keys`, `~/.private_keys`, `~/.appstoreconnect/private_keys` and `~/Downloads` of the user the server runs as. Contents are never returned |
| `POST /setup/asc-keys/use` | `UseASCKeyRequest` `{path, issuerID?}` | Local only. As `POST /settings/asc-key`, with the key read from `path`, which must be one the scan finds at that moment (else `400` `asc_key_not_found`); the key ID comes from the file name |
| `GET /setup/github` | | Local only. `200` `GitHubCLIStatus` `{ghLogin?}`: the login of the GitHub CLI's active github.com account (`gh api user --jq .login`, with Homebrew's directories on `PATH`, 15 s at most) |
| `POST /setup/github/use-gh` | | Local only. `200` `GitHubLoginResponse` `{login}`. Copies `gh auth token --hostname github.com` into `HANGAR_GITHUB_TOKEN` after checking it as `POST /settings/github-token` does; the token never appears in a response, a command line or a log. `400` `gh_not_signed_in` without a gh login. `GitHubStatus.source` is `gh` while the stored token is the one copied |
| `POST /setup/local-worker` | | Local only. `202` `LocalWorkerInstall` `{state: running, lines}`. Installs and enrolls the worker on the server's own Mac for the server's user: creates a pairing code and runs the `GET /install` script for `http://<bound address>:<port>` (loopback when bound to every interface) with `HANGAR_PAIRING_CODE`, `HANGAR_MACHINE_NAME` (`LocalHostName`) and `HANGAR_BIN_DIR` (`~/.local/bin` unless the server's environment sets it); of the server's environment only `HOME`, `PATH`, `USER`, `LOGNAME`, `TMPDIR`, `LANG`, `SHELL`, `HANGAR_BIN_DIR`, `HANGAR_WORKER_CONFIG` and `HANGAR_NO_LAUNCHD` reach the script. One install at a time: a second call returns the running one; an install still running after 10 minutes is stopped and fails, and one that exits 0 without enrolling this Mac fails too. `409` `dedicated_user_required` unless the server runs as the macOS user `hangar` (builds must not run as the user that holds `master.key`, and the server does not `sudo`; the message gives the install command to run in Terminal, which creates that user), `409` `machine_exists` when this Mac is enrolled, `409` `worker_already_installed` when a worker is already set up here (its configuration exists, or its launchd agent is loaded; not asked under `HANGAR_NO_LAUNCHD=1`): the install never replaces or restarts it, and its message offers the update command only when the worker's configuration names its server. `503` `worker_binary_missing`, `host_name_unknown`, `server_address_unusable` (`--port 0`) |
| `GET /setup/local-worker` | | Local only. `200` `LocalWorkerInstall` `{state: running|succeeded|failed, lines, machine?, message?}`: the last install since the server started (its last 200 output lines; `machine` once enrolled, `message` when it failed); `404` `not_found` when none ran |
| `GET /asc/apps` | | `200` `[ASCAppSummary]` `{id, name, bundleID, registered, iconURL?}` sorted by name, the team's apps from App Store Connect; `registered` is true when a Hangar app already uses that ID; `iconURL` (https, 512 px) is absent when no icon was found (each source is given up after 5 s); `409` `asc_not_configured` without the key |
| `GET /signing` | | `200` `SigningStatus` `{state, identity?, canCreate, createBlockedReason?, nextCreationAt?}`: the server's one Apple Development identity, which VM archives sign with (see [Signing](#signing)). `state` is `none`, `active`, `expiring` (within 30 days of `identity.expiresAt`) or `expired`; `identity` is `SigningIdentityInfo` `{name, teamID?, serialNumber, expiresAt, createdAt, origin: "created"\|"imported", ascCertificateID?}`. Never the `.p12` or its password |
| `POST /signing/certificate` | | `201` `SigningCreateResponse` `{status, revokedCertificateID?, revokeProblem?}`. Create, or Renew: one `DEVELOPMENT` certificate through App Store Connect with the team key. `409` `signing_identity_exists` while an identity is valid for more than 30 days, `429` `signing_rate_limited` within 24 hours of the last certificate Hangar created, `409` `asc_not_configured` or `team_key_required`, `502` `asc_refused` with App Store Connect's words. Renewing revokes the previous certificate only if Hangar created it, by its stored ID; `revokeProblem` says when that failed (the new one is in use either way). No API token may call it |
| `POST /signing/import` | `ImportSigningIdentityRequest` `{p12 (base64), password}` | `201` `SigningStatus`. Adopts an Apple Development `.p12` the owner has; creates nothing at Apple and never revokes it. The certificate and key must match and be valid; the identity is packed again under a password of the server's. `400` `invalid_identity` (wrong password, no key, not Apple Development, expired), `409` `signing_identity_exists` while one is stored. No API token may call it |
| `DELETE /signing` | | `200` `SigningStatus`. Deletes the stored copy; the certificate is not revoked. No API token may call it |
| `GET /github/repos` | | `200` `[GitHubRepo]` `{fullName, htmlURL, isPrivate, defaultBranch, description?, pushedAt?, archived}`: every repository the global `HANGAR_GITHUB_TOKEN` can see (`GET /user/repos`, owner, collaborator and organization member; at most 10 pages of 100), most recently pushed first; cached in memory for 5 minutes per token, so a new token is never served the old token's list; `409` `github_not_configured` without a token; `502` `github_unauthorized` when GitHub refuses it |
| `GET /github/repos/{owner}/{repo}/inspect?ref=` | `ref` optional (the default branch) | `200` `RepositoryInspection` `{commit, apps: [DetectedApp], projects, notes, hasWorkflowFile, appStoreConnectUnavailable, appStoreConnectError?}`, read with the global token (none for a public repository) before the app exists in Hangar. A `DetectedApp` `{name, bundleIDs, platforms, schemes: [DetectedScheme], icon: DetectedIcon?, appStoreConnect: ASCAppSummary?}` is one or more application targets that share a bundle ID (`PRODUCT_BUNDLE_IDENTIFIER` from XcodeGen's `project.yml`, or `bundleIdPrefix` and the target's name, else `project.pbxproj`; a bundle ID built from settings the file does not set is left out); apps no scheme builds (an embedded helper) are dropped. Without `ref`, `404` `repository_not_found` when GitHub has no such repository for the token. With the App Store Connect key, each app is matched by bundle ID (`GET /v1/apps?filter[bundleId]=`) and takes its App Store Connect name; matched apps come first. When App Store Connect is configured but fails, `appStoreConnectUnavailable` is true, `appStoreConnectError` says why (never its response text), and no app is matched. `hasWorkflowFile`: the repository has its own `.hangar.yml`. Trees and files read at a commit are cached for 10 minutes per repository, commit and token, so a `workflow-suggestion` right after reads nothing again. Files over 8 MB are not read (a note says so). `projects` lists every workspace and project, the chosen one first. Errors as for `workflow-suggestion` |
| `GET /github/repos/{owner}/{repo}/icon?commit=&path=` | `commit` a SHA; `path` an image inside an `.appiconset` | `200` the PNG or JPEG bytes (at most 5 MB, checked against `Content-Length` first), cached for an hour; `400` `invalid_path` for any other path; `404` `icon_not_found` when it is not a PNG or JPEG |
| `GET /apps/{id}/workflow-suggestion?ref=&bundleID=` | both optional; `ref` defaults to the default branch | `200` `WorkflowSuggestion` `{commit, yaml, notes, workflows: WorkflowFile, schemes: [DetectedScheme], icon: DetectedIcon?, hasWorkflowFile, projects, testPlans, whatToTestFiles}`: a `release` workflow worked out from the repository (with the app's token, as `.hangar.yml` reads): the top-most workspace (not one inside a project, nor deeper than the top-most project), else project, else the project XcodeGen's `project.yml` generates; shared schemes (else XcodeGen's, else the application targets), each scheme's platform from XcodeGen or the target's `SDKROOT`; the team; the highest Xcode version online machines report; `tools` (`xcodegen`, and `brew` when `ci_scripts` use it); export `app-store-connect` and no post-actions. When the repository builds several apps, only the schemes of the app with `bundleID` (else this app's bundle ID from App Store Connect, `GET /v1/apps/{id}`) are archived; without either, every app's are, with a note. `yaml` parses to `workflows`; `notes` say what was guessed. `schemes` lists every scheme found, sorted; a `DetectedScheme` is `{name, platform?, isApplication, hasTests}`, where `hasTests` means its scheme lists test targets (XcodeGen `test.targets`, a shared scheme's `TestableReference`) or a unit or UI test target is named after it (`<Name>Tests`, `<Name>UITests`). `projects` lists every workspace and project, the chosen one first; `testPlans` the names of the `.xctestplan` files; `whatToTestFiles` the `TestFlight/WhatToTest.<locale>.txt` files next to the project. `icon` is the first app's: the largest image of its `.appiconset` (`kind: "appiconset"`) or an Icon Composer `.icon` bundle (`kind: "iconcomposer"`, which only a build can render). `Pods`, `Carthage`, `.build`, `DerivedData` and `node_modules` are skipped. Nothing is stored. `422` `no_project_found`; `504` `detection_timeout` after 15 s; `404` `ref_not_found` |
| `GET /apps/{id}/beta-groups` | | `200` `[BetaGroup]` `{id, name, isInternal}`: the app's TestFlight groups in App Store Connect, internal ones first, each set by name. `409` `asc_not_configured` without the App Store Connect key; `502` `asc_refused` when App Store Connect refuses, with its own words in the message |
| `POST /apps/{id}/beta-groups` | `{name}` | `201` `BetaGroup`: creates an internal group of the app (`POST /v1/betaGroups` with `isInternalGroup: true` and the app relationship). `400` `invalid_request` for an empty name; otherwise as `GET` |
| `GET /apps/{id}/repo-icon?ref=` | `ref` optional | `200` the image of the `appiconset` icon `workflow-suggestion` finds, cached in memory for an hour; `404` `icon_not_found` when there is none (or only an Icon Composer icon) |
| `GET /access` | | `200` `AccessStatus` `{viewerLogin?, viewerToken?, allowedLogins, configured, serverNodeLogin?, serverNodeTagged}`: who is asking (their Tailscale login, or their owner token's name), the logins that count as the owner now, whether they were set (`configured`) or are the server node's own login, and that login (absent while Tailscale is not running, or when the node is tagged). Owner only |
| `PUT /access` | `AccessUpdate` `{allowedLogins}` | `200` `AccessStatus`. Replaces the owner logins; an empty list goes back to the server node's login. `400` `invalid_login` for an empty login or one with spaces or commas; `409` `access_lockout` when a request from the owner's device would leave its own login out. Owner only |
| `GET /api-tokens` | | `200` `[APIToken]` `{id, name, scope, prefix, createdAt, lastUsedAt?}` sorted by name; never a secret or its hash |
| `POST /api-tokens` | `CreateAPITokenRequest` `{name, scope}` | `201` `CreateAPITokenResponse` `{token: APIToken, secret}`: the only response with the secret (`hgr_` and 43 base64url characters); `prefix` is its first 8 characters. `400` `invalid_name` (empty or over 64 characters), `invalid_scope` for `owner`; `409` `token_exists` |
| `DELETE /api-tokens/{id}` | | `204`; `{id}` is the name or UUID; the token stops working at once. `404` `token_not_found` |
| `GET /api-tokens/current` | | `200` `APIToken`: the token the request carries (any scope); `404` `not_found` without one |
| `GET /events` | | SSE stream, see below |

### Jobs

A `Job`'s `action` is the workflow action it runs: `{kind: "archive", scheme, platform, export}` or `{kind: "test", scheme, platform, destination?, testPlan?}` (an action without `kind`, stored before test actions existed, is an archive). A deploy creates one job per action of either kind; they share the build's number. A test job's `steps` are `checkout`, `post-clone`, `pre-xcodebuild`, `test`, `post-xcodebuild`, `upload-artifacts` and `cleanup`.

The `archive`, `test` and `export` steps' logs are condensed by the worker: each xcodebuild task is one line starting with `▸ ` ("▸ Compile LegiloKit (arm64)", "▸ Sign Legilo.app"), its invocation is dropped, and everything the tools printed is kept. The log exactly as xcodebuild printed it (masked like every line) is the job's `full-log.txt` artifact, uploaded when the condensed log leaves something out.

#### Test outputs

Once its result bundle is read, a test job's `outputs` hold, as strings: `test.passed`, `test.failed`, `test.skipped`, `test.total`, and `test.failures`, a JSON array of `{name, message}` (one per failing test, its first failure message; at most 50, secrets masked). A `Machine`'s report lists `simulatorRuntimes` (`["iOS 27.2", "visionOS 27.1"]`); the scheduler does not give a simulator test to a machine without a runtime for its platform.

Numbers and deploys ask App Store Connect and Xcode Cloud for the highest known build number. They need the server's App Store Connect key (Settings › App Store Connect); without an issuer ID it is used as an individual key (JWT `sub: "user"`, no `iss`). The server reads it on every request.

**Local only:** the routes marked so act on the server's own Mac (its key files, its GitHub CLI login, installing a worker there), so they answer only requests whose socket peer is this Mac: loopback, the bound address or one of its interface addresses (a browser on this Mac that opens the tailnet name counts). Headers are never trusted for this. A reverse proxy on the same Mac connects from loopback, so behind one every proxied client counts as local. Any other peer gets `403` `local_only`.

## Install routes

These live outside `/api/v1`. They are `GET`s, so the cross-site rules do not apply, but the `Host` check does.

| Method and path | Response |
| --- | --- |
| `GET /install` | `200` `text/plain; charset=utf-8`: the worker install script, run as `curl -fsSL http://<server>:8787/install \| sh` against the server's own address and port (not a `tailscale serve` HTTPS proxy: the script uses the address it was fetched from, always over `http://`). The server's address in it is `http://<Host>`, taken from the request's (already allowed) `Host`; a `Host` that is not a plain DNS name or IP address with a valid port gets `400` `invalid_request`. See [worker setup](worker-setup.md) |
| `GET /install/hangar-worker` | `200` the `hangar-worker` binary next to `hangar-server` (symlinks resolved), `application/octet-stream` with `Content-Length` and `X-Hangar-Version`; `503` `worker_binary_missing` when there is none (install-server.sh installs it, universal: Apple silicon and Intel) |

## Worker routes

Worker machines call these routes under `/api/v1/worker`. Each needs `Authorization: Bearer <machine token>`; a missing or unknown token gets `401` `unauthorized`. A `{id}` job must be assigned to the calling machine, else `409` `job_not_assigned_to_machine`. A job's VM calls its job's routes with a job token instead (see [Job tokens](#job-tokens)).

| Method and path | Request | Response |
| --- | --- | --- |
| `GET /worker/me` | | `200` `Machine`: the machine the token belongs to (never the token); `hangar-worker check` uses it |
| `POST /worker/heartbeat` | `HeartbeatRequest` | `200` `HeartbeatResponse`: the IDs of the machine's jobs a user asked to cancel |
| `GET /worker/jobs/next?wait=` | `wait` in seconds, default 25, at most 60 | `200` `JobAssignment` for the oldest job assigned to the machine; `204` when none is assigned within `wait` |
| `POST /worker/jobs/{id}/start` | | `200` `Job`, now `running`; the job must be `assigned` |
| `POST /worker/jobs/{id}/steps` | `StepUpdate` `{name, status, at, detail?, stages?}` | `200` `Job`; the job must be `running`. `status` adds `warning` and `cancelled`; `detail` is the step's one-line cause or warnings, `stages` `[{name, status, detail?}]` its parts (TestFlight) |
| `POST /worker/jobs/{id}/info` | `JobRunInfo` `{workerVersion?, xcodeVersion?, xcodeBuild?}` | `200` `Job`; merged into the job's `runInfo` (whose `machineName` the server sets at start); the job must be `running` |
| `POST /worker/jobs/{id}/log` | `LogBatch` | `204`; the job must be `running` |
| `POST /worker/jobs/{id}/artifacts/{name}` | the raw file, streamed | `201` `ArtifactInfo`; the job must be `running` |
| `POST /worker/jobs/{id}/finish` | `JobResult` with `succeeded`, `failed` or `cancelled` | `200` `Job`; the job must be `assigned` or `running`. Deletes the job's job tokens |
| `POST /worker/jobs/{id}/token` | | `201` `JobTokenResponse` `{token}`: a new job token for the job; the job must be `assigned` or `running` (else `409` `job_state_conflict`). Machine token only |
| `POST /worker/jobs/{id}/provisioning` | `JobProvisioningRequest` `{useServerIdentity}` | `200` `JobProvisioning` `{profiles: [{bundleID, name, uuid, isMac, content (base64)}], missing: [{bundleID, reason}], developmentKey?, notes}`: what a VM archive's guest signs with (see *VM archives* below). Only for an archive assigned to this machine, `assigned` or `running` (`409` `job_state_conflict`), on a machine whose report has `vm` (`400` `not_a_vm_archive`). Machine token only; a job token gets `403` |
| `DELETE /worker/jobs/{id}/token` | | `204`: deletes the job tokens this machine was given for the job (another machine's stay). Idempotent, and allowed after the job ended or moved. Machine token only |

A `JobAssignment` carries the job's environment for its build's workflow, with values, resolved as `GET /apps/{id}/environment` describes. An archive assigned to a machine the owner allowed VM builds on (`vmBuilds`), whose report has a `vm` object, also carries `signingIdentity` `{p12 (base64), password}`: the server's signing identity, absent when there is none or it has expired. Host workers and test jobs never get it. It is the only response that holds secret values, and it goes only to the machine the job is assigned to.

`appStoreConnectKey` `{keyID, issuerID?, privateKey}` is the server's App Store Connect key, never part of `environment`. It goes with every job on a host Mac (the worker writes the `.p8` only while its archive, test or export `xcodebuild` and each post-action run, and removes it right after; hooks never see it), and with an archive on a VM Mac, whose host keeps it for the export and never passes it to the guest. A VM Mac's test jobs get none. With `GET /worker/jobs/next` and `POST /worker/jobs/{id}/provisioning`, these are the only responses that hold secret values, and they go only to the machine the job is assigned to.

### VM archives

A VM archive is split between the guest and its host, so that no App Store Connect key of the server's enters the guest. Before the VM boots, the host asks `POST /worker/jobs/{id}/provisioning`. For the app's own bundle IDs (its App Store Connect bundle ID and every registered bundle ID under it, of the archive's platform), the server returns an active development profile of the platform's type that holds Hangar's signing certificate, and creates one only when there is none: development profiles only, with that certificate and the team's enabled devices, logged and listed in `notes`. It never reads or changes a distribution profile. What it cannot provide is in `missing`, and then the optional development key comes too. An iOS, tvOS, visionOS or watchOS archive with a missing profile and no development key fails before its VM boots; a macOS one goes on, since an app that needs no profile signs with the certificate alone.

The guest signs for development with those profiles: manual signing through an `-xcconfig`, without `-allowProvisioningUpdates` and without any Apple account. With the development key it signs automatically with that key instead. It reports `checkout` through `stamp` and then `post-xcodebuild` itself, and ends with a hand-off instead of a result. The host copies the archive, the result bundle, the TestFlight notes and the full log out of the VM (`tar` over SSH, into a staging directory; a link that leaves the copy, or anything but files, directories and links, fails the job), deletes the VM, and runs `export`, the post-actions, `upload-artifacts` and `cleanup` itself with the server's key. Then it reports the result with its machine token.

### Signing

VM archives sign with one Apple Development identity kept on the server (Settings › Signing, `hangar signing`). Hangar creates its certificate only on the owner's explicit request, through `POST /signing/certificate`, never from a job, a worker or an MCP tool, and at most once: a valid identity refuses another until its last 30 days, and the server creates at most one certificate per 24 hours whatever happens (counted from the request; a definite refusal from App Store Connect does not count). `POST /signing/import` adopts an existing `.p12` instead. The `.p12` and its password are sealed with the server's master key, like secret variables. Distribution signing is untouched: exports stay cloud-managed with the App Store Connect key.

### Job tokens

A machine that runs its jobs in VMs gives each job's VM a job token in place of its machine token (`POST /worker/jobs/{id}/token`). It is `hgj_` and 43 base64url characters, returned once; only its SHA-256 is stored. Sent as `Authorization: Bearer hgj_…`, it acts as the machine it was issued to, for that one job:

- **Allowed**, only with the token's own job as `{id}`: `POST /worker/jobs/{id}/start`, `/info`, `/steps`, `/log`, `/artifacts/{name}` and `/finish`, with the same rules as for the machine token.
- **Refused with `403` `job_token_scope`**: every other worker route (`me`, `heartbeat`, `jobs/next`, issuing or revoking job tokens) and any route of another job.
- **Refused with `401` `invalid_job_token`** (before the scope is looked at): a token that is unknown or revoked, or whose job has ended (`succeeded`, `failed`, `cancelled`, however it got there) or is no longer assigned to the token's machine (requeued or reassigned). So a cancel, a lost-worker failure or a requeue ends it without a revoke.

`finish` deletes the job's tokens; `DELETE /worker/jobs/{id}/token` deletes them sooner (e.g. once the VM is gone). Removing the machine deletes its tokens too. Machine tokens behave as before.

### The `vm` object of a machine report

A `MachineReport` (the heartbeat's `report`, and a `Machine`'s `report`) has a `vm` object when the worker is configured for VM builds; such a machine runs every job in a VM and none on the host. It is absent for a machine that builds on the host, and from an older worker.

| Field | Meaning |
| --- | --- |
| `slots` | VM slots ready to take a job: `0` while something is missing (the network filter, an image). With `0` the machine takes no jobs |
| `configuredSlots` | Slots the worker is configured for (`vm.slots`), ready or not; defaults to `slots` |
| `freeSlots` | Ready slots without a job; defaults to `slots` |
| `storageFreeGB` | Free space on the VM storage volume |
| `networkFilter` | The pf anchor that keeps guests off the host and the LAN is loaded |
| `problem` | Why no slot is ready, in plain English ("the network filter is not installed: run …"); absent when `slots` > 0 |
| `ownIdentity` | The worker holds its own signing identity (`hangar-worker vm identity import`), which overrides the server's; absent means `false` |
| `images` | The prepared images: `[{name, macOS, xcode?, xcodeBuild?, simulatorRuntimes}]`. `name` is the image's directory name (`xcode-27.2`), `macOS` the guest's (`26.6.2 (25G83)`), `xcode` the Xcode version in it (absent for an image without Xcode), `simulatorRuntimes` its runtimes (`["iOS 27.2"]`) |

The scheduler judges such a machine by its VMs: it takes a job per ready slot (not `maxConcurrentJobs`), `xcode:` must match an image's `xcode`, a simulator test needs a runtime in one of the images, `storageFreeGB` counts as its free disk, a workflow's `tools:` are not required (a `ci_post_clone.sh` installs them), and it has no Xcode account, so an archive needs a team App Store Connect key. Its queue notes add `VM builds not ready: <problem>` (instead of `busy`) and `no VM image with Xcode <version>`; both block a deploy. An archive also needs a signing identity: while the server has none (or it has expired) and the worker no `ownIdentity`, its note says so and points at Settings › Signing, and that blocks a deploy too.

## Errors

Every error is a JSON body `{"code": "...", "message": "..."}` with one of these statuses.

| Status | Codes |
| --- | --- |
| `400` | `invalid_request` (malformed body or query), `asc_key_not_found`, `asc_key_rejected`, `asc_key_forbidden`, `invalid_asc_key`, `invalid_key_id`, `github_token_rejected`, `invalid_token`, `gh_not_signed_in`, `invalid_job_result`, `invalid_name`, `invalid_variable_name`, `invalid_workflows`, `reserved_variable`, `invalid_artifact_name`, `invalid_workflow_file`, `workflow_file_missing`, `approval_not_supported`, `unsupported_repository`, `invalid_path`, `invalid_identity`, `invalid_scope`, `invalid_login`, `invalid_repository`, `ref_not_allowed`, `value_required` |
| `401` | `authentication_required` (neither the owner's device nor an API token), `unauthorized` (worker routes), `invalid_api_token`, `invalid_job_token` |
| `403` | `cross_site_request`, `invalid_pairing_code`, `local_only`, `token_scope`, `job_token_scope`, `owner_only` |
| `404` | `not_found` (no such route), `app_not_found`, `build_not_found`, `job_not_found`, `machine_not_found`, `workflow_not_found`, `artifact_not_found`, `ref_not_found`, `icon_not_found`, `token_not_found`, `variable_not_found`, `variable_group_not_found`, `repository_not_found` (no such repository, or the token cannot read it) |
| `409` | `app_exists`, `machine_exists`, `bump_not_higher`, `job_not_assigned_to_machine`, `job_state_conflict` (the job is not in a state that allows the call), `asc_not_configured`, `github_not_configured`, `issuer_required` (the App Store Connect key needs its issuer ID), `worker_already_installed`, `token_exists`, `variable_workflows_overlap`, `variable_exists`, `variable_group_exists`, `signing_identity_exists`, `signing_busy` (another change to the signing certificate is running), `team_key_required` (creating a certificate needs a team key), `access_lockout` |
| `415` | `unsupported_media_type` |
| `422` | `no_project_found` (no Xcode project in the repository) |
| `421` | `host_not_allowed` |
| `429` | `too_many_attempts` (`POST /enroll`), `signing_rate_limited` (`POST /signing/certificate`) |
| `502` | `app_store_connect_not_configured`, `build_number_source_unavailable` (the message names the source), `build_number_not_integer`, `source_host_error` (also a GitHub response Hangar cannot read), `file_too_large`, `github_unauthorized` (GitHub refused the token; the message says whether it was the app's own `HANGAR_GITHUB_TOKEN`), `upstream_unavailable`, `asc_unavailable`, `asc_refused` |
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

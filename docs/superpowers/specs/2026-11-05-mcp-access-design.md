# MCP access for AI agents

Date: 2026-11-05
Status: draft

## Intent

Agents should be able to do what a person does in the web UI: add an app from a repository, set up its workflows,
deploy, and follow the build to its artifacts. The existing plugin's skills drive the `hangar` CLI through a shell,
which works but gives the agent no schema, no guard rails and no way to scope what it may do. An MCP server fixes
that.

## Shape

- **`hangar mcp`**: a subcommand of the existing CLI that speaks MCP (JSON-RPC 2.0, newline-delimited) on stdio. It
  is a client of the server's public HTTP API like the CLI and the web UI; it adds no server-side logic of its own.
  One binary to install, and the plugin's `.mcp.json` starts it.
- **`HangarMCP` library**: the protocol loop and the tool handlers, so tests run them against a stub transport
  without a process or a server.
- **API tokens** on the server: the MCP server needs a credential that can be scoped and revoked without touching
  anything else.

## API tokens

The public API has no authentication today: it trusts the tailnet (Host allow-list, cross-site guard, local-only
routes for this Mac). Tokens do not change that for the web UI or the CLI. They add a bounded channel:

- A token is `hgr_` and 43 base64url characters (256 bits). Only its SHA-256 is stored, with a name, a scope, the
  first 8 characters for display, its creation time and when it was last used (updated at most once a minute).
  Revoking deletes the row.
- Created and revoked from **Settings → Agent Access** or `hangar tokens create|list|revoke`. The secret is shown
  once.
- A request with `Authorization: Bearer hgr_…` on a public route is checked: unknown or revoked is `401`
  `invalid_api_token` (it never falls back to the open API), and a route outside the token's scope is `403`
  `token_scope`. Requests without that header behave exactly as before. Worker routes keep their machine tokens.
- Scopes nest: **read** < **deploy** < **configure**.
  - read: every `GET` except the local-only setup routes and the token routes.
  - deploy: also `POST /builds` and `POST /builds/{id}/cancel`.
  - configure: also `POST`/`DELETE /apps`, `PUT`/`DELETE /apps/{id}/workflow-file`, `POST /apps/{id}/beta-groups`,
    `PUT /apps/{id}/numbers/next`.
  - Never with a token: variables, settings, setup, machines, enrolment and token management. An agent cannot mint
    itself a broader token or read or change secrets.
- `GET /api-tokens/current` tells a token its own name and scope. Every non-GET request made with a token is logged
  with the token's name.

What this is not: a lock on the API. Anyone on the tailnet can still call it without a token, as today. A token
bounds what an agent does through MCP and makes it revocable and attributable; locking the API down for everyone
is a separate decision (it would need the web UI to sign in).

## Secrets

The MCP server reads the token from `HANGAR_API_TOKEN` (never an argument, which `ps` would show) and sends it only
in the `Authorization` header. No tool returns a variable value, a token, a key or artifact contents. Log tails pass
through as the server already masks secrets in logs.

## Tools

Read (scope read):
`server_status`, `list_apps`, `list_repositories`, `inspect_repo`, `list_app_store_connect_apps`, `get_workflows`,
`suggest_workflow`, `list_branches`, `deploy_check`, `list_builds`, `get_build`, `wait_for_build`, `get_build_log`,
`list_artifacts`, `list_machines`, `list_testflight_groups`.

Change Hangar (scope configure): `add_app`, `set_workflow` (dry run by default), `clear_workflow_file`
(`confirm: true`), `delete_app` (`confirm_slug` must repeat the app's slug).

Outward-facing: `start_build` (scope deploy, `confirm: true`; reserves a build number and can upload to App Store
Connect, add to TestFlight groups or submit for review, as the workflow's post-actions say; refuses when the deploy
check finds no Mac that can run an action unless `allow_blocked`), `cancel_build` (deploy, `confirm: true`),
`create_testflight_group` (configure, `confirm: true`; creates a real group in App Store Connect).

`set_workflow` takes either a whole YAML file or one workflow as JSON (the API's `Workflow` shape, merged into the
current file under its name), or `remove` a workflow by name. It parses the result with the server's own parser,
warns about TestFlight groups that do not exist in App Store Connect and actions whose scheme the repository does
not have, and returns a unified diff against the file in effect. With `dry_run: false` it stores the file
(`PUT /apps/{id}/workflow-file`).

`get_build` condenses a build for an agent: each job's action, status, machine, current or failed step, queue note,
failure reason, test totals and failing tests, and for a failed job the last 30 log lines of its failed step.
`get_build_log` returns at most 1000 lines and 64 KB, from the end. `wait_for_build` polls until the build finishes
or a timeout (at most 10 minutes) and returns what `get_build` would.

Tool failures come back as tool results with `isError: true` and the server's code and message, so the agent can
react; protocol errors stay JSON-RPC errors.

## Not in scope

Variables and secrets, machines and pairing, server settings, approving post-actions, downloading artifacts through
MCP (the result names each artifact's download URL instead).

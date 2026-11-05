# MCP access for AI agents

`hangar mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server on stdio. It gives an agent such as Claude Code the same things a person does in the web UI: add an app, set up its workflows, deploy, and follow the build to its logs and artifacts. It is a client of the server's [HTTP API](api.md), like the CLI, and authenticates with an API token, so the server decides what the agent may do.

## Set up

1. **Create a token.** In the web UI open **Settings › Agent Access › New Token**, or run:

   ```sh
   hangar tokens create "Claude Code on MacBook" --scope deploy
   ```

   The token (`hgr_…`) is shown once. Pick the narrowest scope:

   | Scope | Can |
   | --- | --- |
   | `read` | Look at apps, repositories, workflows, branches, deploy checks, builds, logs, artifacts, machines and TestFlight groups. |
   | `deploy` | Also start and cancel builds. A build can upload to App Store Connect and TestFlight, as its workflow says. |
   | `configure` | Also add and delete apps, store or clear workflows, and create TestFlight groups. |

   No token can read or change variables or settings, add or remove machines, or create, list or revoke tokens. Revoke a token in Settings or with `hangar tokens revoke <name>`; it stops working at once.

2. **Register the server with Claude Code** on the Mac where Claude Code runs, with `hangar` on its `PATH`:

   ```sh
   claude mcp add hangar --scope user \
     --env HANGAR_SERVER=http://<server>:8787 \
     --env HANGAR_API_TOKEN=hgr_… \
     -- hangar mcp
   ```

   The New Token sheet shows this command with the server's address and the token filled in. `claude mcp list` should then show `hangar` as connected.

   Or load the plugin (`claude --plugin-dir plugins/hangar`), whose `.mcp.json` starts `hangar mcp` with `HANGAR_SERVER` and `HANGAR_API_TOKEN` from Claude Code's environment.

3. **Other agents** start `hangar mcp` as a stdio server with `HANGAR_SERVER` (or `--server`) and `HANGAR_API_TOKEN` in its environment. The token is never read from an argument, where `ps` would show it.

Ask the agent, for example, "add the acme/legilo repository to Hangar and set up a TestFlight workflow", "deploy Legilo to TestFlight from main" or "why did the last Legilo build fail?".

## Tools

Read (any scope):

| Tool | What it does |
| --- | --- |
| `server_status` | Server version, the token's name and scope, whether App Store Connect and GitHub are set up, the signing certificate's state (read only: no tool can create, renew, import or remove it), Macs online. |
| `list_apps` | Apps in Hangar: slug, name, repository, App Store Connect ID. |
| `list_repositories` | Repositories the server's GitHub token can see; `query` filters. |
| `inspect_repo` | The apps a repository builds (bundle IDs, platforms, schemes), their App Store Connect match and the `add_app` input for each. |
| `list_app_store_connect_apps` | The team's App Store Connect apps. |
| `get_workflows` | The workflows in effect at a ref, where they come from (Hangar or the repository's `.hangar.yml`), the YAML, actions, start branches and TestFlight groups. |
| `suggest_workflow` | A workflow worked out from the repository, as the workflow wizard does. Stores nothing. |
| `list_branches` | The repository's branches, the default first. |
| `deploy_check` | Whether every action has a Mac that can run it now, and why not. |
| `list_builds` | Recent builds with each job's state. |
| `get_build` | A build's status, each job's step, machine, queue note, failure reason, test results, and the end of a failed step's log. |
| `wait_for_build` | Waits up to 10 minutes for a build to finish, then returns `get_build`'s answer. |
| `get_build_log` | The end of a job's log, at most 1000 lines and 64 KB, optionally one step. xcodebuild's output is condensed to one `▸` line per task with every diagnostic kept; `raw: true` gives it uncondensed. |
| `list_artifacts` | Each job's artifacts with their download URLs (never their contents). |
| `list_machines` | Build Macs: online, paused (builds turned off; agents cannot pause or resume a Mac), Xcode versions, simulator runtimes, tools, signing, disk. |
| `list_variables` | The app's variables by name (never values): each for all workflows or limited to some, and its linked variable groups in precedence order. With `workflow`: what a job of that workflow gets and where each name comes from. Agents cannot change variables. |
| `list_testflight_groups` | The app's TestFlight groups. |

Change Hangar (`configure`):

| Tool | What it does |
| --- | --- |
| `add_app` | Registers an app from a repository and its App Store Connect ID. |
| `set_workflow` | Sets the workflow file stored in Hangar from a whole YAML file, one workflow as JSON (merged by name) or a removal. Validates it with the server's parser, warns about TestFlight groups App Store Connect does not have and schemes the repository does not have, and returns a diff. **Dry run unless `dry_run: false`.** Structured edits rewrite the file in canonical form, dropping comments. |
| `clear_workflow_file` | Deletes the stored workflow file so builds use the repository's `.hangar.yml` again. Needs `confirm: true`. |
| `delete_app` | Removes an app and its whole history from Hangar. `confirm_slug` must repeat the slug. |

Outward-facing:

| Tool | Scope | What it does |
| --- | --- | --- |
| `start_build` | `deploy` | Deploys a workflow. Reserves a build number for good and runs the workflow's post-actions (upload to App Store Connect, TestFlight groups, beta review). Needs `confirm: true`. Runs a deploy check first and refuses when an action cannot run on any Mac, unless `allow_blocked: true`. Without `ref`, uses the workflow's first start branch, else the default branch. |
| `cancel_build` | `deploy` | Cancels a build. Needs `confirm: true`. |
| `create_testflight_group` | `configure` | Creates a real TestFlight group in App Store Connect, which Hangar cannot delete. Needs `confirm: true`. |

Each tool carries MCP hints (`readOnlyHint`, `destructiveHint`, `openWorldHint`), so a client can ask before the outward-facing ones. A refused confirmation, a missing argument or a server error comes back as a tool result with `isError: true` and the server's code and message, such as `token_scope` when the token's scope is too narrow.

## Secrets

The token travels only in the `Authorization` header to the server. No tool returns a variable's value, a token, a key, or an artifact's contents. Logs pass through as the server stores them, with secret values already masked.

An API token bounds what an agent does through `hangar mcp`. It does not lock the API: without a token the API still trusts the tailnet, as the web UI and the CLI always have. See [API tokens](api.md#api-tokens).

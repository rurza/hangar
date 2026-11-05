# Hangar plugin for Claude Code

- **MCP server** (`hangar mcp`): tools to add apps, set up workflows, deploy, and follow builds, logs and artifacts. See [MCP access](../../docs/mcp.md) for every tool.
- Two skills over the `hangar` CLI, the fallback when the MCP server is not set up:
  - `hangar-deploy`: build and ship an app to TestFlight.
  - `hangar-status`: what is building, why a build is queued or failed, build logs.

## Prerequisites

- `hangar` on PATH.
- `HANGAR_SERVER` set to the server's URL. The author's setup:

  ```sh
  export HANGAR_SERVER=http://rurzomac-mini:8787
  ```

- For the MCP server, `HANGAR_API_TOKEN` set to an API token: create one in the web UI under Settings › Agent Access, or with `hangar tokens create claude --scope deploy`. Pick the narrowest scope that does the job (`read`, `deploy` or `configure`).

## Install

Load it locally, no marketplace needed:

```sh
claude --plugin-dir plugins/hangar
```

The plugin's `.mcp.json` starts `hangar mcp` with `HANGAR_SERVER` and `HANGAR_API_TOKEN` from the environment Claude Code runs in. Then ask, for example, "what is Hangar building?" or "deploy Legilo to TestFlight".

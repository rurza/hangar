# Hangar plugin for Claude Code

Two skills over the `hangar` CLI:

- `hangar-deploy`: build and ship an app to TestFlight.
- `hangar-status`: what is building, why a build is queued or failed, build logs.

## Prerequisites

- `hangar` on PATH.
- `HANGAR_SERVER` set to the server's URL. The author's setup:

  ```sh
  export HANGAR_SERVER=http://rurzomac-mini:8787
  ```

## Install

Load it locally, no marketplace needed:

```sh
claude --plugin-dir plugins/hangar
```

Then ask, for example, "what is Hangar building?".

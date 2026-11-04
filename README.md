# Hangar

Hangar is a self-hosted build fleet for Apple apps. It runs the workflows you would otherwise run on Xcode Cloud, on Macs you own.

- **Xcode Cloud compatible.** Your `ci_scripts/` hooks (`ci_post_clone.sh`, `ci_pre_xcodebuild.sh`, `ci_post_xcodebuild.sh`) run unchanged and see the usual `CI_*` variables. `CI_HANGAR=TRUE` is also set so a script can tell the two apart; `CI_XCODE_CLOUD` is not.
- **Self-hosted.** A server and one or more workers on your tailnet. Nothing is exposed outside it.
- **Build numbers that never collide with Xcode Cloud.** The next number is one more than the highest known in Hangar, App Store Connect and Xcode Cloud, so you can use both systems on the same app.

## Status

Phase 1: the TestFlight path (archive, export, upload to App Store Connect, wait for processing, add to beta groups). The Developer ID path (notarized direct distribution) comes in Phase 2.

## Architecture

- `hangar-server`: control plane on one always-on Mac. Stores apps, builds and encrypted secrets, schedules jobs, serves the HTTP API.
- `hangar-worker`: runs on each build Mac as a launchd agent. Heartbeats, long-polls for jobs, runs them with Xcode.
- `hangar`: command-line client for the server API.
- `plugins/hangar`: Claude Code plugin with deploy and status skills over the CLI.

## Quick start

Requires macOS 15+, Xcode and [Tailscale](https://tailscale.com) on every Mac. Details: [server setup](docs/server-setup.md), [worker setup](docs/worker-setup.md).

1. **Install the server** (and the CLI) on the always-on Mac:

   ```sh
   scripts/server/install-server.sh
   ```

2. **Point the CLI at it**, from any Mac on the tailnet:

   ```sh
   export HANGAR_SERVER=http://<tailnet-host>:8787
   ```

3. **Create a machine and install the worker** on each build Mac, as the dedicated `hangar` user (prepare it as described in the worker setup):

   ```sh
   hangar machines add <name>        # prints the worker token once
   read -rs HANGAR_WORKER_TOKEN; export HANGAR_WORKER_TOKEN
   scripts/worker/install-worker.sh --server http://<tailnet-host>:8787
   hangar-worker doctor
   hangar machines list
   ```

4. **Set the App Store Connect key and a GitHub token:**

   ```sh
   hangar settings asc-key --key-id <id> --issuer-id <id> --p8 AuthKey_<id>.p8
   hangar settings github-token      # reads the token from stdin
   ```

5. **Add an app:**

   ```sh
   hangar apps add MyApp --repo https://github.com/<you>/<repo> --asc-app-id <id>
   hangar numbers myapp
   ```

6. **Add `.hangar.yml` to the app repo** (see [hangar-yml](docs/hangar-yml.md)):

   ```yaml
   version: 1
   workflows:
     testflight:
       project: MyApp.xcodeproj
       xcode: "27.2"
       actions:
         - { scheme: MyApp, platform: ios, export: app-store-connect }
       post-actions:
         - testflight
   ```

7. **Deploy and watch:**

   ```sh
   hangar deploy myapp testflight --ref main   # watches when run in a terminal
   hangar status
   hangar logs <build-id> --follow
   ```

## Documentation

- [Server setup](docs/server-setup.md)
- [Worker setup](docs/worker-setup.md)
- [`.hangar.yml` reference](docs/hangar-yml.md)
- [HTTP API](docs/api.md)
- [Claude Code plugin](plugins/hangar/README.md)

## License

MIT

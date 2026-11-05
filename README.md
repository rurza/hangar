# Hangar

Hangar is a self-hosted build fleet for Apple apps. It runs the workflows you would otherwise run on Xcode Cloud, on Macs you own.

- **Xcode Cloud compatible.** Your `ci_scripts/` hooks (`ci_post_clone.sh`, `ci_pre_xcodebuild.sh`, `ci_post_xcodebuild.sh`) run unchanged and see the usual `CI_*` variables. `CI_HANGAR=TRUE` is also set so a script can tell the two apart; `CI_XCODE_CLOUD` is not.
- **Archive and test actions.** Like Xcode Cloud, a workflow archives schemes (and uploads to TestFlight) and runs their tests on the Mac or a simulator, with the pass/fail totals and failing tests on the build page.
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

1. **Install the server** on the always-on Mac. Add `--bin-dir ~/.local/bin` to install without sudo (the install scripts no longer read `INSTALL_DIR`; use `--bin-dir`):

   ```sh
   scripts/server/install-server.sh
   ```

2. **Open the web UI** at `http://<server>:8787` (the server's tailnet address) and follow it through:
   - **Settings**: add the App Store Connect key and a GitHub token. (An individual API key has no issuer ID; leave it empty. xcodebuild only accepts team keys, so builds then sign and upload with the Apple account signed in to Xcode on each build Mac, see the [worker setup](docs/worker-setup.md). Hangar still uses the individual key for build numbers and TestFlight.)
   - **Apps → Add app**: name, repository and App Store Connect app.
   - **Workflow**: define the workflow for the app (the editor writes the same configuration as [`.hangar.yml`](docs/hangar-yml.md), which you can also keep in the repo).
   - **Machines → Add machine**: it shows a one-time token and the install commands. Run them on the build Mac, as the dedicated `hangar` user (prepared as described in the worker setup), from a checkout of this repository:

     ```sh
     read -rs HANGAR_WORKER_TOKEN; export HANGAR_WORKER_TOKEN
     scripts/worker/install-worker.sh --server http://<server>:8787    # add --bin-dir ~/.local/bin to skip sudo
     hangar-worker doctor
     ```

   - **Deploy**: pick the app, workflow and ref, and watch the build live.

The same steps are available from the command line (`hangar settings`, `hangar apps add`, `hangar machines add`, `hangar deploy`, `hangar status`, `hangar logs --follow`, with `HANGAR_SERVER=http://<server>:8787` set); see the [HTTP API](docs/api.md) and the [`.hangar.yml` reference](docs/hangar-yml.md).

## Documentation

- [Server setup](docs/server-setup.md)
- [Worker setup](docs/worker-setup.md)
- [`.hangar.yml` reference](docs/hangar-yml.md)
- [HTTP API](docs/api.md)
- [Claude Code plugin](plugins/hangar/README.md)

## License

MIT

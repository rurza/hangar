# Hangar Web UI and In-App Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The author can do everything from a browser on the tailnet: add an app (repo, App Store Connect app), enter the ASC key, GitHub token and secrets, define the app's workflow without committing a file, add machines, deploy, and watch the build live — then this runs for real on `rurzomac-mini`.

**Architecture:** A dependency-free web app (HTML, CSS, ES-module JavaScript, no build step, no CDN) bundled as SwiftPM resources of `HangarServer` and served by the same Hummingbird router at `/`, talking only to the existing `/api/v1` routes plus a few new ones. Workflows gain a second source: a per-app workflow file stored on the server (the same `.hangar.yml` YAML, validated by `WorkflowFileParser`); when present it is used instead of the repository's file.

**Tech Stack:** Swift 6.4, Hummingbird 2, GRDB 7, Swift Testing; browser side: plain HTML/CSS/JS (ES2022 modules), `EventSource` for SSE.

**Spec:** `/Users/adam/Developer/hangar/docs/superpowers/specs/2026-11-04-hangar-design.md` (sections "Web UI (direction B)", "Environment variables and secrets", "Workflows live in the app repo"). Phase 1 plan: `docs/superpowers/plans/2026-11-04-hangar-phase-1.md`.

## Decisions (made by the builder at the author's request on 2026-11-04: "everything clickable, workflow set in the UI")

1. **Workflow defined in Hangar.** Each app may have one server-stored workflow file (YAML text, same schema as `.hangar.yml`). Deploy, `GET /apps/{id}/workflows` and the CLI use it when it exists; otherwise the repository's `.hangar.yml` at the resolved commit is required, as before. The spec's "the only addition is `.hangar.yml`" still holds for repos; Hangar still never edits app repos. The UI offers "Copy as .hangar.yml" so a stored workflow can be moved into the repo later.
2. **UI is static files served by the server**, no Node toolchain: everything ships in the Swift package and works offline on the tailnet.
3. **App picker from App Store Connect.** When the ASC key is configured the "Add app" sheet lists the team's apps (name, bundle ID, ASC app ID) so the author picks instead of typing IDs.
4. **Install scripts accept `--bin-dir`** (default `/usr/local/bin`) so a non-admin install into `~/.local/bin` works without sudo.

## Global Constraints

- Everything from the Phase 1 plan's Global Constraints still binds (Swift 6 strict concurrency, Swift Testing, no real ASC/GitHub/xcodebuild in tests, plain commit messages with no AI attribution).
- Secrets are write-only: no page, API response or CLI output shows a secret value after entry. The UI never pre-fills a secret field; replacing means typing a new value.
- UI text, code and docs in English. Look: "something Apple makes for consumers" — large title, app cards with icons, machines as widgets with utilisation rings, a Deploy sheet; light and dark follow the system (`prefers-color-scheme`); works on a phone (no horizontal scroll at 375 px).
- No external network requests from the UI (no CDN, no web fonts): system font stack `-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif`.
- Content-Security-Policy on UI responses: `default-src 'self'; img-src 'self' https: data:; style-src 'self'; script-src 'self'; connect-src 'self'`. No inline scripts or styles.
- Live updates over SSE (`GET /api/v1/events`, `GET /api/v1/jobs/{id}/log?follow=1`); frames as in `docs/api.md` (event data for `/events` is the full `ServerEvent` JSON).
- The UI talks only to `/api/v1` public routes; never the worker routes.

## Review Focus

1. A stored workflow file with a YAML error → saving is refused with the parser's message shown next to the editor; nothing is stored (Task 1, Task 5).
2. Deploy when the ASC key is not configured or ASC is unreachable → the Deploy sheet shows the server's message instead of a number and the Deploy button stays disabled (Task 6).
3. A secret value never appears in any API response, including `GET /settings` and `GET /apps/{id}/workflow-file` (Task 1, Task 2).
4. Browser reloaded on a deep link (`/apps/legilo`, `/builds/<id>`) → the page loads (SPA fallback), while unknown `/api/v1/...` paths still return JSON 404 (Task 3).
5. A path like `/assets/../hangar.sqlite` or `/assets/%2e%2e/master.key` → 404, never a file outside the bundled web root (Task 3).

---

### Task 1: Server-stored workflow files

**Files:**
- Modify: `Sources/HangarServer/Database/Migrations.swift` (add migration `v3`: table `app_workflows(app_id TEXT PRIMARY KEY REFERENCES apps(id) ON DELETE CASCADE, yaml TEXT NOT NULL, updated_at REAL NOT NULL)`)
- Create: `Sources/HangarServer/Repositories/WorkflowFileRepository.swift`
- Create: `Sources/HangarServer/API/WorkflowFileAPI.swift`
- Modify: `Sources/HangarServer/Builds/BuildService.swift` (`workflows(app:ref:)`), `Sources/HangarServer/API/Router.swift` (mount), `Sources/HangarServer/HangarServerApp.swift` (repository wiring)
- Modify: `Sources/HangarCore/API/Requests.swift` (`WorkflowsResponse` + new DTOs)
- Modify: `Sources/hangar/Commands/Workflows.swift` (print the source; add `hangar workflows <app> --set <file.yml>` / `--clear`)
- Modify: `docs/api.md`, `docs/hangar-yml.md`
- Test: `Tests/HangarServerTests/WorkflowFileAPITests.swift`, update `BuildServiceTests`, `Tests/hangarTests/CommandParsingTests.swift`

**Interfaces:**
- Produces (HangarCore):
  - `enum WorkflowSource: String, Codable, Sendable { case hangar, repository }`
  - `WorkflowsResponse { commit: String; workflows: WorkflowFile; source: WorkflowSource }` (new field; `commit` is the resolved SHA in both cases).
  - `struct StoredWorkflowFile: Codable, Equatable, Sendable { yaml: String; workflows: WorkflowFile; updatedAt: Date }`
  - `struct PutWorkflowFileRequest: Codable, Sendable { yaml: String }`
- Produces (server):
  - `WorkflowFileRepository { get(appID:) throws -> (yaml: String, updatedAt: Date)?; set(appID:, yaml:) throws; delete(appID:) throws }`
  - `GET /api/v1/apps/{id}/workflow-file` → `200 StoredWorkflowFile` or `404 {code: "workflow_file_not_found"}`
  - `PUT /api/v1/apps/{id}/workflow-file` body `PutWorkflowFileRequest` → parse with `WorkflowFileParser`; error → `400 {code: "invalid_workflow_file", message: <WorkflowFileError description>}` and nothing stored; success → `200 StoredWorkflowFile`; publishes nothing.
  - `DELETE /api/v1/apps/{id}/workflow-file` → `204`.
  - `BuildService.workflows(app:ref:)` returns `(commit, file, source)`: resolve the commit first (as today), then a stored file wins; otherwise read `.hangar.yml` as today.

- [ ] **Step 1: Write failing tests.** `WorkflowFileAPITests`: `putValidStoresAndReturnsParsed` (Legilo YAML from `docs/hangar-yml.md` → 200, `workflows.workflows["testflight"]?.actions.count == 2`); `putInvalidIsRefusedAndStoresNothing` (`platform: android` → 400 `invalid_workflow_file`, message contains `android`; then GET → 404); `deleteRemoves`; `deletingAppRemovesItsWorkflowFile`. `BuildServiceTests`: `storedWorkflowFileWinsOverRepository` (fake host serves a different `.hangar.yml`; deploy uses the stored workflow's actions; `workflows(...)` reports `.hangar`); `repositoryFileUsedWhenNoneStored` (source `.repository`). CLI: `workflowsSetSendsFileContents`.
- [ ] **Step 2: Run** `swift test --filter 'WorkflowFileAPITests|BuildServiceTests|CommandParsingTests'`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter, then the full `swift test`. Expected: PASS.
- [ ] **Step 5: Docs** — `docs/api.md` routes; `docs/hangar-yml.md` section "Defining the workflow in Hangar instead".
- [ ] **Step 6: Commit** `feat(server): workflows defined in Hangar as an alternative to .hangar.yml`.

### Task 2: Settings status and App Store Connect app lookup

**Files:**
- Modify: `Sources/HangarAppStoreConnect/AppStoreConnectClient.swift`, `LiveAppStoreConnectClient.swift`, `Models.swift`
- Create: `Sources/HangarServer/API/SettingsAPI.swift`
- Modify: `Sources/HangarServer/API/Router.swift`, `HangarServerApp.swift` (expose the ASC client factory for this route), `Sources/HangarCore/API/Requests.swift`, `docs/api.md`
- Test: `Tests/HangarAppStoreConnectTests/LiveClientDecodingTests.swift` (+ fixture `apps.json`), `Tests/HangarServerTests/SettingsAPITests.swift`; update every fake `AppStoreConnectClient` conformer in tests.

**Interfaces:**
- Produces (ASC): `struct ASCApp: Sendable, Equatable, Codable { id: String; name: String; bundleID: String }`; protocol method `func apps() async throws -> [ASCApp]` (`GET /v1/apps?limit=200&fields[apps]=name,bundleId`, pages through `links.next` with the existing guarded pager).
- Produces (HangarCore): `struct SettingsStatus: Codable, Equatable, Sendable { version: String; appStoreConnect: ASCKeyStatus?; githubTokenSet: Bool }`, `struct ASCKeyStatus: Codable, Equatable, Sendable { keyID: String; issuerID: String }` (both IDs are plain variables; the key itself is never returned); `struct ASCAppSummary: Codable, Equatable, Sendable { id: String; name: String; bundleID: String; registered: Bool }`.
- Produces (server):
  - `GET /api/v1/settings` → `SettingsStatus` (`appStoreConnect` nil unless all three `HANGAR_ASC_*` globals exist; `githubTokenSet` = global `HANGAR_GITHUB_TOKEN` exists).
  - `GET /api/v1/asc/apps` → `[ASCAppSummary]` sorted by name, `registered` = an App with that `appStoreConnectAppID` exists; not configured → `409 {code: "asc_not_configured", message: "Set the App Store Connect key in Settings first."}`; ASC errors → 502 via the existing mapping.

- [ ] **Step 1: Write failing tests.** `appsDecodesAcrossPages`; `settingsReportsNothingConfigured`; `settingsShowsKeyIDsButNeverTheKey` (set the three globals; raw body contains the key ID and issuer, never the `.p8` text); `ascAppsMarksRegistered`; `ascAppsWithoutKeyIs409`.
- [ ] **Step 2: Run** `swift test --filter 'LiveClientDecodingTests|SettingsAPITests'`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter, then full `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(server): settings status and App Store Connect app lookup`.

### Task 3: Serving the web app

**Files:**
- Modify: `Package.swift` (`HangarServer` target `resources: [.copy("Web")]`)
- Create: `Sources/HangarServer/Web/index.html`, `Web/assets/styles.css`, `Web/assets/app.js`, `Web/assets/api.js`, `Web/assets/router.js`, `Web/assets/ui.js`, `Web/assets/icon.svg`
- Create: `Sources/HangarServer/API/WebUI.swift`
- Modify: `Sources/HangarServer/API/Router.swift`, `Sources/hangar-server/HangarServerCommand.swift` (log `Hangar is running at http://<host>:<port>/`)
- Test: `Tests/HangarServerTests/WebUITests.swift`

**Interfaces:**
- Produces (server): `struct WebUI { static var root: URL /* Bundle.module "Web" */; func addRoutes(to router: Router<HangarRequestContext>) }` — `GET /` and any `GET` path not starting with `api/` or `assets/` → `index.html`; `GET /assets/{file}` → that file from `Web/assets` with `Content-Type` by extension (`.js` `text/javascript; charset=utf-8`, `.css` `text/css; charset=utf-8`, `.svg` `image/svg+xml`, `.html` `text/html; charset=utf-8`), `Cache-Control: no-cache`, the CSP from Global Constraints, `X-Content-Type-Options: nosniff`, `Referrer-Policy: same-origin`. Only single-segment names matching `^[A-Za-z0-9._-]+$` and not starting with `.`; anything else 404. Unknown `/api/v1/*` paths keep returning JSON 404.
- Produces (browser, consumed by Tasks 4–7):
  - `api.js`: `export const api = { get(path), post(path, body), put(path, body), del(path) }` — fetches `/api/v1${path}`, JSON in/out, throws `ApiError {status, code, message}` built from the server's `{code, message}`.
  - `api.js`: `export function events(onEvent: (ServerEvent) => void): () => void` (EventSource on `/api/v1/events`, reconnects; returns a close function) and `export function followLog(jobID, step, onEntries, onEnd): () => void`.
  - `router.js`: `export function route(pattern, render)` with patterns `/`, `/apps/:app`, `/apps/:app/workflow`, `/builds`, `/builds/:id`, `/machines`, `/settings`; `navigate(path)`; History API links (`<a data-link>`).
  - `ui.js`: `h(tag, attrs, ...children)` element builder (no innerHTML with data), `sheet({title, body, actions}) → {close}` (modal sheet, Esc closes, focus trapped), `toast(message, kind)`, `ring(fraction, label)` SVG utilisation ring, `relativeTime(date)`, `duration(start, end)`, `statusBadge(status)`.
  - `styles.css`: CSS custom properties for light/dark (`--bg`, `--card`, `--text`, `--secondary`, `--accent` #0A84FF-ish, `--success`, `--failure`, `--warning`, radius 14–18 px), the large-title header, a tab bar (Apps, History, Machines, Settings) that becomes a bottom bar under 640 px.
  - `app.js`: shell — header, nav, page outlet, registers routes (pages are placeholders here; Tasks 4–7 fill them).

- [ ] **Step 1: Write failing tests** (`app.test(.router)`): `rootServesIndex` (200, `text/html`, body contains `<div id="app">`, CSP header exact); `deepLinkServesIndex` (`/apps/legilo`, `/builds/x`); `assetServedWithType` (`/assets/app.js` → `text/javascript`); `traversalIs404` (`/assets/..%2Fhangar.sqlite`, `/assets/%2e%2e/master.key`, `/assets/.hidden` → 404); `unknownAPIPathStaysJSON404` (`/api/v1/nope` → 404 JSON with `code`).
- [ ] **Step 2: Run** `swift test --filter WebUITests`. Expected: compile failure.
- [ ] **Step 3: Implement** server routes and the shell assets (shell renders the header and tab bar; each page shows its title).
- [ ] **Step 4: Run** the filter, then full `swift test`. Expected: PASS. Also `node --check` is NOT available-guaranteed; instead run `swift build` and open nothing — the controller verifies in a browser.
- [ ] **Step 5: Commit** `feat(server): serve the Hangar web app`.

### Task 4: Apps, app detail and variables

**Files:**
- Create: `Sources/HangarServer/Web/assets/pages/apps.js`, `pages/app-detail.js`, `pages/variables.js` (variables editor reused by Settings for globals)
- Modify: `Web/assets/app.js` (register), `Web/assets/styles.css`

**Interfaces:**
- Consumes: `api`, `router`, `ui` from Task 3; routes `GET/POST/DELETE /apps`, `GET /apps/{id}/numbers`, `PUT /apps/{id}/numbers/next`, `GET /builds?app=&limit=20`, variables routes, `GET /asc/apps`, `GET /apps/{id}/workflow-file`.
- Produces: `export function variablesEditor({scope: "global" | {app: slug}}) → HTMLElement` (list name, kind badge Plain/Secret, as-file badge, updated; plain values are not shown either — the API returns none; "Add variable" sheet: name, value (textarea when as-file), Secret toggle, As file toggle; "Replace" opens the same sheet with an empty value; "Delete" confirms).

Behaviour:
- Apps page (`/`): large title "Apps", a grid of cards (icon or a rounded-square monogram with a colour derived from the name; name; latest build number + status; "Deploy" button opening the Task 6 sheet via `openDeploySheet(app)` imported from `pages/deploy.js` — until Task 6 exists, import lazily and show nothing if missing is NOT allowed: Task 4 creates `pages/deploy.js` exporting `openDeploySheet(app)` that shows a toast "Deploy arrives in the next step"; Task 6 replaces its body), "Add app" card.
- Add app sheet: if `GET /settings` says ASC is configured, a searchable list from `GET /asc/apps` (registered ones disabled) fills name and ASC app ID; repository URL field (`https://github.com/<owner>/<repo>`), optional icon URL; on 409 `asc_not_configured` show a link to Settings and allow typing the ASC app ID by hand. Errors from `POST /apps` shown inline.
- App detail (`/apps/:app`): title = app name, subtitle = repo; cards: "Next build number" (from `numbers`; shows `next`, highest ASC, last Xcode Cloud run, in-flight flag; 502/409 shows the message; "Raise…" sheet → `PUT numbers/next`, 409 shows "must be higher than N"); "Workflow" (source: "Defined in Hangar" or "From .hangar.yml" or "Not defined" with a button to the editor `/apps/:app/workflow`); "Recent builds" list (number, workflow, ref, status badge, relative time, links to `/builds/:id`); "Environment" (`variablesEditor({app})`); danger zone "Remove app" (confirm by typing the app name).
- Live: subscribe to `events()`; on `build` events for this app re-render the builds list and app card.

- [ ] **Step 1: Implement** the three modules and register routes.
- [ ] **Step 2: Verify** `swift build` and `swift test --filter WebUITests` still pass (assets bundled); grep that no module uses `innerHTML` with API data (`grep -n innerHTML Sources/HangarServer/Web -r` → only static strings or none).
- [ ] **Step 3: Commit** `feat(web): apps, app detail and environment variables`.

### Task 5: Workflow editor

**Files:**
- Create: `Sources/HangarServer/Web/assets/pages/workflow.js`, `Web/assets/yaml.js`
- Modify: `Web/assets/app.js`, `styles.css`

**Interfaces:**
- Consumes: `GET/PUT/DELETE /apps/{id}/workflow-file`, `GET /apps/{id}/workflows?ref=main` (to import the repo's file), `GET /machines` (to offer installed Xcode versions and reported tools as suggestions).
- Produces: `yaml.js`: `export function workflowToYAML(file: {version, workflows: {[name]: Workflow}}) → string` emitting exactly the shape documented in `docs/hangar-yml.md` (keys `project`|`workspace`, `xcode` quoted, `team` quoted when present, `tools` flow list, `actions` as `- { scheme: X, platform: ios, export: app-store-connect }`, `post-actions` with `- testflight:` and its kebab-case settings only when they differ from defaults; `requires-approval` never emitted in Phase 1). Strings are double-quoted when they contain any of `:#{}[],&*?|<>=!%@` or start with a digit or are empty.

Behaviour (`/apps/:app/workflow`):
- Loads the stored file; if none, offers "Start from the repository's .hangar.yml" (imports via `workflows?ref=main`, shows the error if the repo has none) or "Start from scratch" (one workflow named `testflight`).
- Form per workflow: name; Project or Workspace path (segmented control + text); Xcode version (text with datalist of versions reported by online machines); Team ID (optional); Tools (chips with datalist from machine reports); Actions table (scheme, platform select ios/macos/visionos/tvos/watchos, export select App Store Connect/Developer ID; add/remove rows); Post-actions: TestFlight toggle with settings (wait for processing, timeout minutes, groups chips, What to Test toggle, submit for external review). Add/remove workflow.
- "YAML" tab shows `workflowToYAML(...)` read-only with "Copy as .hangar.yml".
- Save → `PUT workflow-file {yaml}`; a 400 shows the parser message above the form and keeps the edits; success toast "Workflow saved". "Remove Hangar workflow" → DELETE (then deploys use the repo's file again).
- Note under the title: "Builds use this workflow instead of the repository's .hangar.yml."

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify** a round trip outside the browser: add `Tests/HangarServerTests/WorkflowYAMLRoundTripTests.swift` that runs `/usr/bin/osascript -l JavaScript` (JXA, present on every Mac) to load `yaml.js`'s function source and serialize the Legilo workflow, then parses the output with `WorkflowFileParser` and compares to the expected `WorkflowFile`. If loading an ES module in JXA is impractical, keep `workflowToYAML` in a file with no `import`/`export` except a final `export { workflowToYAML }` line the test strips. Run `swift test --filter WorkflowYAMLRoundTripTests` → PASS.
- [ ] **Step 3: Commit** `feat(web): workflow editor`.

### Task 6: Deploy sheet, build detail and history

**Files:**
- Modify: `Web/assets/pages/deploy.js` (replace the stub)
- Create: `Web/assets/pages/build.js`, `Web/assets/pages/history.js`
- Modify: `Web/assets/app.js`, `styles.css`

**Behaviour:**
- `openDeploySheet(app)`: fields Workflow (select from `GET /apps/{id}/workflows?ref=<ref>`; shows source; refreshes when ref changes, debounced), Branch or commit (default `main`), Where (Automatic or one of the machines, with each machine's online state), build-number preview (`GET /apps/{id}/numbers`; error message replaces the number and disables Deploy), post-actions summary (e.g. "TestFlight · groups: Internal · wait for processing"), actions per workflow listed as "LegiloMobile · iOS". Deploy → `POST /builds`; success navigates to `/builds/:id`; errors (refNotFound, workflow errors, numbering) shown inline.
- Build detail (`/builds/:id`): header "Build 311" + app + workflow + ref (short SHA) + status badge + started/duration; one card per job: scheme/platform, machine name, queue note when queued, steps list with status icons and durations (running step pulses), failure reason, outputs (e.g. TestFlight build state), artifacts (`GET /jobs/{id}/artifacts` with download links), a log panel following `followLog(job, null, …)` (monospaced, auto-scroll unless the user scrolled up, `HH:MM:SS [step] line`, capped at the last 5,000 lines in the DOM), "Cancel build" while not terminal. Live via `events()` (`build`/`job` events for this build).
- History (`/builds`): table/list of the last 50 builds across apps (app, number, workflow, ref, status, relative time, duration), filter by app, live updates.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify** `swift build`; controller checks in a browser later.
- [ ] **Step 3: Commit** `feat(web): deploy sheet, live build detail and history`.

### Task 7: Machines and settings

**Files:**
- Create: `Web/assets/pages/machines.js`, `Web/assets/pages/settings.js`
- Modify: `Web/assets/app.js`, `styles.css`

**Behaviour:**
- Machines (`/machines`): widgets per machine — name, online dot (offline after 90 s like `Machine.isOnline`), utilisation ring (running jobs / max), chip, performance cores, memory, free disk, power (AC/battery), Xcode versions, tools chips, "Can sign without a prompt" check or warning with a hint, last seen. "Add machine" sheet: name, max concurrent jobs → shows the token ONCE with copy button and the exact install commands from `docs/worker-setup.md` (`read -rs HANGAR_WORKER_TOKEN` … `install-worker.sh --server <this server's origin>`), warning "Save this token now; it is not shown again." "Remove machine" with confirm.
- Settings (`/settings`): "App Store Connect" card — status from `GET /settings` (Key ID / Issuer shown when configured); form Key ID, Issuer ID, `.p8` file input (read with `FileReader` as text) → three `PUT /variables/...` calls exactly like `hangar settings asc-key` (KEY_ID and ISSUER_ID plain, KEY_PATH secret + as-file with the file contents); after saving, refresh status. "GitHub" card — token field (password input, never pre-filled) → `PUT /variables/HANGAR_GITHUB_TOKEN {secret, not as-file}`; shows "Token set" state with Replace/Remove. "Global variables" — `variablesEditor({scope: "global"})` hiding the reserved `HANGAR_ASC_*` and `HANGAR_GITHUB_TOKEN` names (managed by the cards above). "About" — version, server address.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify** `swift build`.
- [ ] **Step 3: Commit** `feat(web): machines and settings`.

### Task 8: Install without sudo and first run on rurzomac-mini

**Files:**
- Modify: `scripts/server/install-server.sh`, `scripts/worker/install-worker.sh` (`--bin-dir <dir>`, default `/usr/local/bin`; the rendered plist uses that path), `docs/server-setup.md`, `docs/worker-setup.md`, `README.md` (UI first: "Open http://<server>:8787 and follow Settings → Apps → Workflow → Deploy")

- [ ] **Step 1: Implement** the flag; `bash -n` both scripts; render and `plutil -lint` a plist with `--bin-dir "$HOME/.local/bin"`.
- [ ] **Step 2: Commit** `feat(scripts): install into a chosen bin directory`.
- [ ] **Step 3 (controller, on rurzomac-mini):** install the server with `--bin-dir ~/.local/bin` (binds the Tailscale address), create a machine through the API, install the worker for the current user with that token, confirm `GET /api/v1/machines` shows it online, and walk the UI in a browser: Apps, Add app sheet, workflow editor save/refuse, Settings cards, Machines widget, Deploy sheet error state without an ASC key.

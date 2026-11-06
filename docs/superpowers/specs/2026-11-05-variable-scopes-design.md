# Variable scopes: shared groups and per-workflow variables

Date: 2026-11-05
Status: implemented on the variable-scopes branch

## Intent

Two things the Environment section cannot do today:

1. **Share variables between some apps.** A Sentry auth token used by three of five apps is either set three times
   or made global, and then every app's jobs get it.
2. **Give a workflow its own value.** `SENTRY_DSN` for "Beta" is not the one for "Release", but an app variable
   reaches every job of the app.

## Shape

- **Variable groups** (managed in Settings → Variable Groups). A group has a name and variables, secret or plain,
  as a file or not, exactly like global ones. Nothing gets a group's variables until an app *links* it. The name
  follows the wording other CI systems use for the same thing (Azure Pipelines' variable groups, GitLab's group
  variables); Xcode Cloud has no such feature to borrow a name from: its environment is per workflow.
- **Links.** An app links any number of groups. Each link applies to all of the app's workflows or only to chosen
  ones.
- **Workflow restriction on app variables.** Each app variable is for "All workflows" or for a chosen set of
  workflow names. The same name may exist several times in one app: at most once for all workflows, plus any number
  of rows limited to disjoint sets of workflows. Global and group variables have no restriction of their own; a
  group is restricted through its link.

## Precedence

A job of workflow *W* gets, for each name, the value from the first of these that defines it:

1. an app variable limited to *W*,
2. the app variable for all workflows,
3. a linked group limited to *W*,
4. a linked group for all workflows,
5. a global variable.

Within 3 and within 4, the group listed higher on the app's page wins: links are kept in the order they were made,
first on top. Rejecting two groups that define the same name was the alternative; it was not chosen because a group
is edited in Settings, away from the apps that link it, and adding a variable to one group would then have to be
refused because of some app's other link. The order is shown, and the help text says it.

Where no workflow is known (the server's own GitHub calls before a workflow is chosen, the scheduler's team-key
check), only the layers that do not depend on a workflow count: 2, 4 and 5.

Overlap between restricted app variables of one name is refused (`409` `variable_workflows_overlap`, naming the
workflows both would cover), so a workflow never has two values at the same level.

## Reserved names

The `HANGAR_*` names keep their rules: the App Store Connect key is set in Settings (since 2026-11-06 a server
setting, not a variable); `HANGAR_GITHUB_TOKEN` is global or per app. The server reads them without a workflow, so:

- a `HANGAR_*` app variable cannot be limited to workflows (`400` `reserved_variable`);
- a group cannot hold a `HANGAR_*` name (`400` `reserved_variable`).

The UI's existing checks (`CI_*`, `PATH` and the other names Hangar sets for every job) apply to groups too.

## Workflow names that went away

A restriction names workflows by name, and a workflow can be renamed or removed. A variable limited only to names
that no longer exist reaches no job, which must not happen silently:

- The app page reads the app's workflow names (the stored file, else the repository's `.hangar.yml` at the default
  branch) and marks every name in a restriction or a link that is not among them: "“Beta” is not a workflow of this
  app any more."
- The deploy check adds a notice `unknown-workflow-names` for each app variable and link that names a workflow the
  deployed commit's workflow file does not have.

Renaming a workflow does not rewrite restrictions; the warning says what to fix.

## Deploy check

`undefined-variables` uses the environment of the workflow being deployed. A name the scripts read that the app
sets only for other workflows is still undefined, and the sentence says where it is set: "…isn’t defined in Hangar
for this workflow (only for “Beta”)…".

## Data

Migration `v9`:

- `variables` is rebuilt (SQLite cannot change a UNIQUE constraint) with an `id`, `owner_id` in place of `app_id`
  (`''` global, the app's or the group's id) and `workflows` (`''` for all workflows, else a JSON array of names,
  sorted). The constraint becomes `UNIQUE (scope, owner_id, name, workflows)`. `scope` gains `'group'`. Every
  existing row is copied with `workflows = ''`: the same behaviour as before.
- `variable_groups (id, name UNIQUE COLLATE NOCASE, created_at)`.
- `app_variable_groups (app_id → apps ON DELETE CASCADE, group_id → variable_groups ON DELETE CASCADE, workflows,
  position, PRIMARY KEY (app_id, group_id))`.

A group's variables go with the group; an app's variables and links go with the app.

## API

Types (`HangarCore`): `VariableScope` gains `{"group": "<uuid>"}`; `VariableSummary` and `VariableInput` gain
`workflows: [String]` (empty or absent: all workflows), so old clients keep working.

| Route | Body | Result |
|---|---|---|
| `PUT /apps/{id}/variables/{name}` | `VariableInput` | Sets the row for exactly `workflows`; a new restricted row must not overlap another of the name |
| `PATCH /apps/{id}/variables/{name}?workflow=…` | `VariableUpdate` `{workflows?, value?, isSecret?, asFile?}` | Changes the row the `workflow` parameters name (none: the one for all workflows); `404` `variable_not_found` |
| `DELETE /apps/{id}/variables/{name}?workflow=…` | | Deletes that row |
| `GET /apps/{id}/environment?workflow=` | | `[EffectiveVariable]`: the names a job of that workflow gets and where each comes from; no values |
| `GET /variable-groups` | | `[VariableGroup]` with variables (no values) and the apps that link each |
| `POST /variable-groups` | `{name}` | `201` `VariableGroup`; `409` `variable_group_exists` |
| `PATCH /variable-groups/{group}` | `{name}` | Renames |
| `DELETE /variable-groups/{group}` | | Deletes it, its variables and its links |
| `GET /variable-groups/{group}/variables` | | `[VariableSummary]` |
| `PUT`/`DELETE /variable-groups/{group}/variables/{name}` | `VariableInput` | As for global variables; `workflows` must be empty |
| `GET /apps/{id}/variable-groups` | | `[AppVariableGroupLink]` in precedence order |
| `PUT /apps/{id}/variable-groups/{group}` | `{workflows}` | Links, or changes the link's workflows (keeps its place) |
| `DELETE /apps/{id}/variable-groups/{group}` | | Unlinks |

`{group}` is the group's id or name. The `workflow` query parameter repeats, one per name.

API tokens: every `GET` above is scope read (names and flags, never values, as for the existing variable routes);
no token may change a variable, a group or a link.

## Secrets

Unchanged: a value is sealed on the way in and only a `JobAssignment` carries it, to the machine the job is
assigned to. The new routes return names, flags, workflows and sources. Error messages name variables and
workflows, never values.

## UI

- **App page, Environment.** Each variable row shows "All workflows" or the names it is limited to; Edit changes the
  restriction and, optionally, the value (empty keeps it). Below the variables, **Linked Groups** lists the app's
  links in precedence order, each with its variables' names and its workflows, with Edit and Unlink; Link Group adds
  one. The footer states the precedence in one sentence.
- **Settings, Variable Groups.** One card per group: its variables (the same editor as global variables), which apps
  link it, Rename and Delete. Deleting asks first and names the apps that lose the group.
- **Secret by default for names that look secret.** The Add sheet starts with Secret off; it now turns Secret on
  while the name looks like a secret (a `_`-separated part that is `TOKEN`, `SECRET`, `KEY`, `PASSWORD`, `PASSWD`,
  `PWD`, `CREDENTIAL(S)` or `PRIVATE`, or a compound such as `APIKEY` or `ACCESSTOKEN`; `SENTRY_DSN` and `MONKEY`
  do not), until the person flips the switch themselves. A stored plain variable whose name looks secret gets a hint in its row; its data is not changed.

## CLI and MCP

- `hangar var set|list|remove` gain `--workflow <name>` (repeatable) for app variables; `hangar var list --app x
  --workflow W` shows the environment workflow W gets, with sources. `hangar var group create|list|rename|remove`
  manage groups, `--group <name>` on `set|list|remove` their variables, and `hangar var link|unlink <group> --app x
  [--workflow …]` the links.
- MCP: a read tool `list_variables` (app, optional workflow) returns names, flags, workflows and sources, never
  values. It deviates from the MCP spec's "variables are not in scope": API tokens could already list variable names
  with any `GET`, and an agent reading an `undefined-variables` notice needs to see where a name is set. Changing
  variables stays outside every token scope.

## Global secrets are opt-in per app (2026-11-06)

Added after the security review of 2026-11-06 (C1): a global *secret* reached every job of every app.

- **Plain globals stay inherited** by every app, as before.
- **A global secret reaches only the apps that receive it** (`app_global_secrets (app_id, name)`). The app page's
  **Global Secrets** section lists every global secret with Receive / Stop Receiving; `GET/PUT/DELETE
  /apps/{id}/global-secrets[/{name}]` does the same (names only; no API token may change it).
- **The precedence is unchanged** for what an app does get: layer 5 counts only a global secret the app receives.
  An app variable or a linked group of the same name needs no grant and wins as before.
- **Migration `v12`** grants every existing app every existing global secret, so nothing changes until someone
  stops one. Afterwards a new global secret reaches no app until it is chosen; a plain global that becomes secret
  keeps reaching every app that had it (all of them); deleting a global secret deletes its grants.
- **The deploy check** names a global secret a script reads that the app does not receive, and says where to
  choose it.
- **Reserved names keep their rules.** The App Store Connect key is no longer a variable at all (`HANGAR_ASC_*` is
  refused at every scope; it is a server setting, see the VM builds design, decision 23). `HANGAR_GITHUB_TOKEN`
  is not opt-in: checkout needs it. The app's own variable wins, and the app page warns while jobs clone with the
  global one and recommends a fine-grained, read-only token for the app's repository.

## Not in scope

Reordering links (unlink and link again to move one to the bottom), rewriting restrictions when a workflow is
renamed, per-workflow global variables, and group-level restrictions independent of links.

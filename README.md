# fabric-item-promote

**Promote Microsoft Fabric items, not commits.**

A GitHub Actions workflow that promotes *selected* Fabric items (notebooks, pipelines,
variable libraries, ...) from one Git branch to the next (feature → dev → test → prod)
through a reviewed pull request, with Fabric-aware dependency checks.

## The problem

Fabric Git integration with one branch per environment (`develop` → `test` → `main`,
each deployed to its own workspace) works well until a branch holds several changes and
only one of them is ready.

`git cherry-pick` doesn't help, because Fabric commits don't follow your changes. A single
workspace commit (*"Committing 5 items from workspace"*) can contain a notebook fix, a
schedule tweak and three unfinished experiments. The unit you develop, review and deploy in
Fabric is the **item**, so that's the unit this tool promotes.

## How it works

1. You run **Promote Fabric items** from the Actions tab and pick:
   - **Copy FROM**: a feature branch (type its name), `develop` or `test`
   - **Copy INTO**: `develop`, `test` or `main`
   - **Items**: folder names, comma-separated, e.g. `Sales_Load.Notebook, Ingest_Sales.DataPipeline`
     (a bare name is found anywhere in the repo; a full path is only needed when the name is ambiguous)
   - **Dry run**: preview only
2. The workflow creates `promote/<source>-to-<target>-<timestamp>` from the **target** branch and
   sets each selected item folder to **exactly** its state on the source branch, including deleted
   files and deleted items. Nothing else from the source branch comes along.
3. It runs the dependency checks (below) and opens a PR with the items, the check results, the
   changed files and a reviewer checklist.
4. You review and merge as normal. Your existing deploy-on-push workflow takes it from there.

The promotion order is enforced: any branch → `develop`, `develop` → `test`, `test` → `main`.
Going backwards or skipping an environment fails.

## Fabric-aware checks

| Check | Result |
|---|---|
| A promoted notebook `%run`s (or `notebook.run("…")`s) a notebook the target branch doesn't have | ❌ **Blocks** the promotion |
| A promoted pipeline uses `@pipeline().libraryVariables.<x>` and the target's Variable Library doesn't declare `<x>` | ❌ **Blocks** |
| A `%run` dependency exists on both branches but **differs** (you may need the newer helper notebook too) | ⚠️ Warns |
| A promoted item references another item's `logicalId` (e.g. a pipeline's `notebookId`) that isn't on the target | ⚠️ Warns |
| The target has commits on a promoted item that the source doesn't, so the promotion would **undo** them | ⚠️ Warns, listing the commits |

### Why the "undo" warning matters

The promotion branch starts from the target, so the PR is always a clean fast-forward.
GitHub shows **"no conflicts"** even when the copy reverts someone's newer change on the
target, such as a schedule edited in the workspace and committed straight to `develop`.
The diff shows it, but a two-line revert is easy to miss in a large PR. The workflow lists
those commits in the PR description:

```
**Changes on `develop` that this promotion undoes**
- ⚠️ `Load/Sales_Load.Notebook`: `develop` has changes that `feature/sales-refresh` doesn't.
  Promoting will undo them unless they're also on the source:
  - `3f9c1e0` Committing 1 item from workspace
```

The usual fix is to merge the target into your feature branch and promote again.

## Setup

1. Copy into your Fabric repo:
   ```
   .github/workflows/promote-fabric-items.yml
   scripts/promote_fabric_items.sh
   scripts/check_fabric_dependencies.py
   ```
2. Put them on your **default branch**. GitHub only lists manually-run workflows from the default
   branch, and the workflow always loads the scripts from it, so `test` and `main` don't need copies.
3. If your branches are named differently, edit `PROMOTION_ORDER` (format `target=source;...`,
   `*` means any branch) and the `target_branch` options in the workflow.
4. Let the workflow open PRs: enable *Settings → Actions → General → Allow GitHub Actions to create
   and approve pull requests*, **or** add a `PROMOTION_TOKEN` secret (a token with `contents` and
   `pull-requests` write). If neither is set, the branch is still pushed and the run summary has a
   pre-filled "create pull request" link.

Requirements: GitHub Actions on `ubuntu-latest` (bash, git, Python 3.10+). No other dependencies.

## When you don't need this

- You deploy from a single `main` branch and handle environments with parameters
  (e.g. fabric-cicd `parameter.yml`).
- You use Fabric **deployment pipelines**, which already let you pick items (without Git review).

## Limitations

- **Whole items only.** You can't promote half of a notebook's changes.
- **Static checks.** References built at run time (`notebook.runMultiple(dag)`, a variable
  library name stored in a constant) and workspace-specific GUIDs (e.g. a default lakehouse)
  aren't detected. The checks are a safety net, not a guarantee.
- **Branches drift.** Promoting selectively means `test` is no longer just an older copy of
  `develop`. The undo warning helps, but merge `develop` into `test` now and then.
- GitHub Actions only (no Azure DevOps version).

## Tests

```bash
bash tests/run_tests.sh
```

Builds a throwaway Fabric-style repo with a local origin and runs 9 dry-run cases (each block,
each warning, promotion order, unknown items). No network needed. CI runs it on every push.

## License

MIT

#!/usr/bin/env bash
# Self-test: builds a throwaway Fabric-style repo with a local "origin" and runs
# promote_fabric_items.sh in dry-run mode against it. No network, no GitHub.
# Usage: bash tests/run_tests.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
promote_script="$repo_root/scripts/promote_fabric_items.sh"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
failures=0

git_quiet() { git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=develop "$@" >/dev/null 2>&1; }

new_item() {  # new_item <folder> <type> <logicalId> <content file name> <content>
  mkdir -p "$1"
  printf '{"metadata":{"type":"%s","displayName":"%s"},"config":{"logicalId":"%s"}}\n' \
    "$2" "$(basename "${1%.*}")" "$3" > "$1/.platform"
  printf '%s\n' "$5" > "$1/$4"
}

# --- Build the repository -------------------------------------------------
git_quiet init --bare "$work_directory/origin.git"
git_quiet clone "$work_directory/origin.git" "$work_directory/repo"
cd "$work_directory/repo"
git_quiet checkout -b develop

new_item Shared/nb_utils.Notebook Notebook 11111111-1111-1111-1111-111111111111 notebook-content.py "def helper(): pass"
new_item Load/Sales_Load.Notebook Notebook 22222222-2222-2222-2222-222222222222 notebook-content.py $'%run nb_utils\nhelper()'
new_item Pipelines/Ingest.DataPipeline DataPipeline 33333333-3333-3333-3333-333333333333 pipeline-content.json \
  '{"value": "@pipeline().libraryVariables.workspace_id"}'
new_item Shared/vl.VariableLibrary VariableLibrary 44444444-4444-4444-4444-444444444444 variables.json \
  '{"variables": [{"name": "workspace_id", "type": "String", "value": ""}]}'
git_quiet add -A && git_quiet commit -m "initial items"
git_quiet branch test && git_quiet branch main

# Feature branch: several changes, only some of them ready.
git_quiet checkout -b feature/sales-refresh
printf '%%run nb_utils\nhelper()\nnew_helper()\n' > Load/Sales_Load.Notebook/notebook-content.py
printf 'def helper(): pass\ndef new_helper(): pass\n' > Shared/nb_utils.Notebook/notebook-content.py
new_item Load/New_Report.Notebook Notebook 55555555-5555-5555-5555-555555555555 notebook-content.py '%run nb_report_helpers'
new_item Shared/nb_report_helpers.Notebook Notebook 66666666-6666-6666-6666-666666666666 notebook-content.py "def report(): pass"
printf '{"value": "@pipeline().libraryVariables.new_connection_id"}\n' > Pipelines/Ingest.DataPipeline/pipeline-content.json
printf '{"variables": [{"name": "workspace_id"}, {"name": "new_connection_id"}]}\n' > Shared/vl.VariableLibrary/variables.json
git_quiet add -A && git_quiet commit -m "feature work"

# Meanwhile someone changes Sales_Load directly on develop (e.g. a workspace commit).
git_quiet checkout develop
printf '%%run nb_utils\nhelper()\n# hotfix on develop\n' > Load/Sales_Load.Notebook/notebook-content.py
git_quiet commit -am "Committing 1 item from workspace"
git_quiet push origin develop test main feature/sales-refresh

# --- Run the cases -----------------------------------------------------------
run_case() {  # run_case <name> <expected exit> <expected output regex> <source> <target> <items>
  local name="$1" expected_exit="$2" expected_output="$3" output actual_exit=0
  # Start each case clean: a blocked case leaves its copied folders staged.
  git reset --quiet --hard && git clean -fdq
  git checkout --quiet --detach origin/develop
  output="$(SOURCE_BRANCH="$4" TARGET_BRANCH="$5" ITEM_LIST="$6" DRY_RUN=true \
    ENFORCE_PROMOTION_ORDER=true PROMOTION_ORDER="develop=*;test=develop;main=test" \
    GITHUB_STEP_SUMMARY=/dev/null bash "$promote_script" 2>&1)" || actual_exit=$?
  if [[ "$actual_exit" == "$expected_exit" ]] && grep -Eq -- "$expected_output" <<< "$output"; then
    echo "PASS  $name"
  else
    echo "FAIL  $name (exit $actual_exit, expected $expected_exit; wanted output matching: $expected_output)"
    echo "$output" | sed 's/^/      /'
    failures=$((failures + 1))
  fi
}

run_case "warns when a %run dependency differs" 0 "runs \`nb_utils\`, which differs" \
  feature/sales-refresh develop Sales_Load.Notebook
run_case "warns when the promotion undoes a change on the target" 0 "Committing 1 item from workspace" \
  feature/sales-refresh develop Sales_Load.Notebook
run_case "blocks when a %run notebook is missing on the target" 1 "nb_report_helpers.Notebook\` is not on the target" \
  feature/sales-refresh develop New_Report.Notebook
run_case "passes when the missing notebook is promoted too" 0 "No missing dependencies" \
  feature/sales-refresh develop "New_Report.Notebook, nb_report_helpers.Notebook"
run_case "blocks when a library variable is missing on the target" 1 "library variable \`new_connection_id\`" \
  feature/sales-refresh develop Ingest.DataPipeline
run_case "passes when the Variable Library is promoted too" 0 "No missing dependencies" \
  feature/sales-refresh develop "Ingest.DataPipeline, vl.VariableLibrary"
run_case "blocks a backwards promotion" 1 "would go backwards" \
  test develop Sales_Load.Notebook
run_case "blocks skipping an environment" 1 "can only receive items from 'test'" \
  develop main Sales_Load.Notebook
run_case "fails on an unknown item" 1 "was not found" \
  feature/sales-refresh develop Does_Not_Exist.Notebook

echo
if [[ $failures -gt 0 ]]; then echo "$failures case(s) failed"; exit 1; fi
echo "All cases passed"

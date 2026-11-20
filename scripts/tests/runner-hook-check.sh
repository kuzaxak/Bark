#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Runs scripts/runner/job-started-hook.sh the way the runner does: `bash -e <hook>` as a child of
# Runner.Worker, after which the job's `if: always()` steps still run.
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cp /bin/bash "$test_dir/Runner.Worker"
hook="$PWD/scripts/runner/job-started-hook.sh"
release=kuzaxak/Nook/.github/workflows/release.yml
candidate=kuzaxak/Nook/.github/workflows/bark-candidate.yml

# job runs|refused <description> [NAME=value ...]
job() {
  local expected="$1" description="$2" status=0
  shift 2
  # shellcheck disable=SC2016
  env -i PATH=/usr/bin:/bin "$@" "$test_dir/Runner.Worker" -c '
    if [[ -n "${CANDIDATE_REF_FIXTURE:-}" ]]; then
      bash -e "$0" --bark-candidate "$CANDIDATE_REF_FIXTURE"
    else
      bash -e "$0"
    fi
    echo "steps ran"
  ' "$hook" < /dev/null \
    > "$test_dir/out" 2>&1 || status=$?
  if [[ "$expected" == runs ]]; then
    if [[ "$status" != 0 ]] || ! grep -qx "steps ran" "$test_dir/out"; then
      echo "FAIL: $description was refused: $(<"$test_dir/out")"; exit 1
    fi
  elif [[ "$status" != 137 ]] || grep -qx "steps ran" "$test_dir/out"; then
    echo "FAIL: $description was not stopped (status $status): $(<"$test_dir/out")"; exit 1
  fi
}

job runs "tag push of release.yml" \
  GITHUB_WORKFLOW_REF="$release@refs/tags/v1.5.3" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v1.5.3
job runs "workflow_dispatch of release.yml" \
  GITHUB_WORKFLOW_REF="$release@refs/heads/develop" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/develop
job refused "pull_request of release.yml" \
  GITHUB_WORKFLOW_REF="$release@refs/pull/7/merge" GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/7/merge
job refused "push of release.yml to a branch" \
  GITHUB_WORKFLOW_REF="$release@refs/heads/develop" GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/develop
job refused "another workflow on a tag" \
  GITHUB_WORKFLOW_REF="kuzaxak/Nook/.github/workflows/macos-build.yml@refs/tags/v1.5.3" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v1.5.3
job refused "a job without the variables"

candidate_ref=refs/heads/develop
job runs "candidate dispatch from the fixed default branch" \
  CANDIDATE_REF_FIXTURE="$candidate_ref" GITHUB_REPOSITORY=kuzaxak/Nook \
  GITHUB_WORKFLOW_REF="$candidate@$candidate_ref" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF="$candidate_ref"
job refused "branch-selected candidate workflow" \
  CANDIDATE_REF_FIXTURE="$candidate_ref" GITHUB_REPOSITORY=kuzaxak/Nook \
  GITHUB_WORKFLOW_REF="$candidate@refs/heads/topic" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/topic
job refused "candidate job with the trusted workflow path and a different event ref" \
  CANDIDATE_REF_FIXTURE="$candidate_ref" GITHUB_REPOSITORY=kuzaxak/Nook \
  GITHUB_WORKFLOW_REF="$candidate@$candidate_ref" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/topic
job refused "pull_request_target on the fixed default branch" \
  CANDIDATE_REF_FIXTURE="$candidate_ref" GITHUB_REPOSITORY=kuzaxak/Nook \
  GITHUB_WORKFLOW_REF="$candidate@$candidate_ref" GITHUB_EVENT_NAME=pull_request_target GITHUB_REF="$candidate_ref"
job refused "fork candidate" \
  CANDIDATE_REF_FIXTURE="$candidate_ref" GITHUB_REPOSITORY=fork/Nook \
  GITHUB_WORKFLOW_REF="fork/Nook/.github/workflows/bark-candidate.yml@$candidate_ref" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF="$candidate_ref"
job refused "legacy workflow on the candidate runner" \
  CANDIDATE_REF_FIXTURE="$candidate_ref" GITHUB_REPOSITORY=kuzaxak/Nook \
  GITHUB_WORKFLOW_REF="$release@$candidate_ref" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF="$candidate_ref"
job refused "candidate workflow on the legacy runner" \
  GITHUB_REPOSITORY=kuzaxak/Nook GITHUB_WORKFLOW_REF="$candidate@$candidate_ref" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF="$candidate_ref"

bark_release=kuzaxak/Nook/.github/workflows/bark-release.yml
job runs "Bark release dispatched on the shipping branch" \
  GITHUB_REPOSITORY=kuzaxak/Nook GITHUB_WORKFLOW_REF="$bark_release@refs/heads/pawl-dev" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/pawl-dev
job refused "Bark release dispatched on a topic branch" \
  GITHUB_REPOSITORY=kuzaxak/Nook GITHUB_WORKFLOW_REF="$bark_release@refs/heads/topic" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/topic
job refused "Bark tag event on the signing runner" \
  GITHUB_REPOSITORY=kuzaxak/Nook GITHUB_WORKFLOW_REF="$bark_release@refs/tags/bark-v2.0.0-rc.1" \
  GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/bark-v2.0.0-rc.1
job refused "Bark fork cannot dispatch to the signing runner" \
  GITHUB_REPOSITORY=fork/Nook GITHUB_WORKFLOW_REF="$bark_release@refs/heads/pawl-dev" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/pawl-dev

echo "runner hook check passed"

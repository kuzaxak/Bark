#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Job-started hook of the self-hosted nook-release runner: by default it takes only
# the Nook tag workflow and the Bark release dispatched from the trusted default branch. Installed
# outside the runner's work directory:
#   cp scripts/runner/job-started-hook.sh ~/actions-runner-nook/hooks/job-started.sh
#   chmod 755 ~/actions-runner-nook/hooks/job-started.sh
#   echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$HOME/actions-runner-nook/hooks/job-started.sh" >> ~/actions-runner-nook/.env
#   cd ~/actions-runner-nook && ./svc.sh stop && ./svc.sh start
#
# On a separate Bark candidate runner, use an out-of-checkout wrapper that
# calls this hook with --bark-candidate and the exact protected default ref.
set -euo pipefail

allowed() {
  if [[ "${1:-}" == --bark-candidate ]]; then
    [[ $# == 2 && "$2" == refs/heads/?* ]] || return 1
    [[ "${GITHUB_REPOSITORY:-}" == kuzaxak/Nook &&
       "${GITHUB_EVENT_NAME:-}" == workflow_dispatch &&
       "${GITHUB_REF:-}" == "$2" &&
       "${GITHUB_WORKFLOW_REF:-}" == "kuzaxak/Nook/.github/workflows/bark-candidate.yml@$2" ]]
    return
  fi
  [[ $# == 0 ]] || return 1
  # The public tag event only dispatches the build. Code on this Mac runs
  # exclusively from the reviewed release workflow on the shipping branch.
  if [[ "${GITHUB_WORKFLOW_REF:-}" == kuzaxak/Nook/.github/workflows/bark-release.yml@refs/heads/pawl-dev ]]; then
    [[ "${GITHUB_REPOSITORY:-}" == kuzaxak/Nook && "${GITHUB_EVENT_NAME:-}" == workflow_dispatch &&
       "${GITHUB_REF:-}" == refs/heads/pawl-dev ]]
    return
  fi
  [[ "${GITHUB_WORKFLOW_REF:-}" == kuzaxak/Nook/.github/workflows/release.yml@* ]] || return 1
  case "${GITHUB_EVENT_NAME:-}" in
    push) [[ "${GITHUB_REF:-}" == refs/tags/v* ]] ;;
    workflow_dispatch) return 0 ;;
    *) return 1 ;;
  esac
}

allowed "$@" && exit 0

echo "Release runner refuses this job: ${GITHUB_WORKFLOW_REF:-no workflow} (${GITHUB_EVENT_NAME:-no event} ${GITHUB_REF:-no ref})"
# The runner runs this hook as a step with if: always(), so a failed hook still lets the job's
# if: always() steps run; the job ends only when its Runner.Worker does.
if [[ "$(ps -o comm= -p "$PPID")" == */Runner.Worker ]]; then kill -KILL "$PPID"; fi
exit 1

# Repository transition runbook

Preparation only. The source is `kuzaxak/Nook`; the proposed standalone
destination is `kuzaxak/Barc`. Confirm the destination and its ownership before
execution. Retain the source repository and its releases through the update
transition. This runbook does not authorize creating, detaching, deleting,
renaming or publishing a repository.

## Preserve and rehearse

1. Record the source repository ID, default branch, all advertised Git refs and
   current release/feed metadata. Pause release writers for the final snapshot;
   compare remote refs before and after export and retry if they changed.
2. Make a mirror and portable bundle outside source control. Restore the bundle
   into a separate bare repository without network access; require identical
   ref names/object IDs and a successful `git fsck --full`. Separately preserve
   unpublished implementation commits and any reviewed uncommitted work: a
   remote mirror does not include them.
3. Export all issues/PRs and their comments/reviews, releases and assets, labels,
   milestones, collaborators, protections/rulesets, repository/Actions settings,
   webhook/deploy-key configuration references, Pages, wiki and linked Projects.
   Include closed/history entries and every API page. A permission failure is
   an unresolved inventory item, not an empty result. When a wiki exists, mirror
   its separate Git repository. Discussions and Projects require their own
   export when present.
4. Download every release asset and verify its size and published digest.
   Preserve the old appcasts alongside the DMGs. Record encrypted-secret names,
   environment bindings, variable configuration and runner labels without
   exporting secret values. Secure configuration omitted from the backup must
   be re-provisioned from its existing owner; a Git bundle cannot restore it.
5. Keep the snapshot, API failures, asset hashes and restore evidence under
   ignored `build/repository-transition/` or a durable backup location. Refresh
   this evidence immediately before the approved operation. The local rehearsal
   proves Git recovery; it does not prove GitHub metadata or updater recovery.

## Stage the independent destination

After explicit authorization for the concrete destination and operation:

1. Create an empty standalone repository with Actions disabled before pushing
   any refs. Do not attach the release runner or signing secrets yet. The
   existing tag-triggered workflow invokes scripts containing `kuzaxak/Nook`
   destinations, so copying it is not a safe release rehearsal.
2. Restore the approved branches and tags. Push only `refs/heads/*` and
   `refs/tags/*`; do not mirror-push GitHub's read-only or unrelated refs. Stop
   on unexpected destination refs instead of overwriting them. Compare every
   restored object ID and verify the destination API reports `fork: false`.
3. Restore applicable settings and metadata, with an explicit account of
   anything GitHub cannot recreate faithfully. Preserve license, authorship and
   upstream acknowledgements. Set the reviewed default branch and retain the
   source repository until the transition is qualified.
4. Update release/source/support destinations in `scripts/release.sh`,
   `.github/workflows/release.yml`, `Nook/Info.plist` and the renamed equivalents.
   Review every release-upload, tag check and appcast URL. Configure runner
   access and signing/provisioning for the new repository only after those
   destinations are correct. Reuse the trusted Sparkle key; changing repositories
   does not justify key rotation. The Barc identity plan owns new App ID,
   CloudKit and provisioning changes.

## Keep installed clients updateable

Existing installations use
`https://github.com/kuzaxak/Nook/releases/latest/download/appcast.xml`.
Keep that endpoint and its referenced assets reachable. The `latest` endpoint
changes when a release becomes latest, so drafts or staging artifacts must not
replace the production feed accidentally.

Before changing either public feed, rehearse the signed Nook → Barc → next Barc
sequence and interrupted installation on native Intel and Apple Silicon. Verify
the real bundle-ID transition, Sparkle trust, destination feed, architecture
selection and data recovery against the rebrand plan. Only publish the reviewed
transition after these checks pass. An unsigned build or reachable URL alone
does not qualify the update path.

Rollback retains the previous signed releases and old feed; it must also retain
new Barc data without copying it into the old Nook namespace. Do not retire the
source or detach its fork network as a cleanup step. If detachment is chosen
instead of the separate destination, obtain approval for its specific metadata
loss and permanent separation after reviewing the refreshed backup and
[GitHub's detachment rules](https://docs.github.com/en/pull-requests/how-tos/work-with-forks/detaching-a-fork).

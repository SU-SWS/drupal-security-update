# Drupal security update

A reusable GitHub Actions workflow that finds security advisories in the code a
Drupal site's production runs on Acquia, and prepares a deployable hotfix that
changes as little as possible. It never deploys; a release engineer deploys the
resulting tag.

For each production tag it:

1. reads that tag's `composer.lock` from the Acquia git repository and audits it;
2. updates only the vulnerable packages, starting with patch releases;
3. installs sites on the production code, switches to the updated code, runs
   the database updates and exports the config;
4. ships config the updates change (committed, or as a patch plus a pull request
   to the package that holds it);
5. commits a hotfix version (`7.0.3` → `7.0.3+1`), pushes it to a
   `security/<version>` branch and pushes the built artifact to Acquia as
   `YYYY-MM-DD_7.0.3+1`;
6. posts to Slack: the tag, updated dependencies, database updates, config pull
   requests, or what failed.

The header of [`.github/workflows/security-update.yml`](.github/workflows/security-update.yml)
describes every step in detail.

## Using it in a site repository

Copy [`examples/caller.yml`](examples/caller.yml) to
`.github/workflows/security-update.yml` in the site repository, choose a
`ref-source`, and add the secrets. The schedule only runs from the site's
default branch.

The site repository needs:

- **`su-sws/sws-drush-commands`.** Builds use `drush sws:artifact:deploy` with its
  options in `drush/drush.yml` (`git-url`, `post-build-script`,
  `artifact-dir`), and test sites are installed with
  `drush drupal:install --site=<site>`.
- **CI database settings the job's MySQL service can satisfy.** Database
  `drupal`, reached as root with no password on `127.0.0.1`, or as
  `drupal`/`drupal` on the host `mysql`. Both work.
- **Release tags.** Production tags are named `YYYY-MM-DD_<release>`, and the
  artifact's commit message has a `Built from <branch>@<sha>` line
  (`sws:artifact:deploy` writes it).

### Where the production tag comes from

| `ref-source` | Uses | Secrets |
|---|---|---|
| `cloud` (default) | The Cloud Platform API: the `acquia-environment` (default `prod`) of each application in `acquia-apps`, defaulting to `command.sws.options.app-id` in `drush/drush.yml`. | `ACQUIA_API_KEY`, `ACQUIA_API_SECRET` |
| `acsf` | The Site Factory API at `acsf-url`, for the stack `acsf-stack-id` (default `1`). | `ACSF_USER`, `ACSF_KEY` |
| either, with `prod-ref` | The given tag, pushed to every `git-url` in `drush/drush.yml`. | none |

If several applications run the same code, list them all in `acquia-apps`.
Applications on the same tag share one hotfix. Each different tag gets its own
hotfix, built one at a time and pushed only to the applications that run it.

### Secrets

Pass them with `secrets: inherit`.

| Secret | Needed for |
|---|---|
| `ACQUIA_SSH_PRIVATE_KEY` | Reading and pushing the Acquia git repositories (dry runs read too). |
| `ACQUIA_API_KEY`, `ACQUIA_API_SECRET` | `ref-source: cloud`. |
| `ACSF_USER`, `ACSF_KEY` | `ref-source: acsf`. |
| `CONFIG_PR_TOKEN` | Optional. Contents and pull request write access to packages that hold config, such as install profiles. Without it, open those pull requests by hand from the report. |
| `SLACK_WEBHOOK_URL` | Optional. Slack messages. |
| `STANFORD_ENCRYPT` | Optional. Set as an environment variable for sites whose settings need it. |
| `TOOLS_TOKEN` | Only if this repository is private: read access to it. |

## Multisites

The test considers `sites` (input), else `command.sws.options.multisites` in
`drush/drush.yml`, else `default`. Sites that share an install profile (from the
site's `sws.yml`, then `project.profile`, then
`command.site.install.profile`) and a config sync directory get the
same updates, so only the first of each group is installed and updated.

## Config the updates change

Production's `drush deploy` imports config right after the database updates, so
config an update changes is reverted unless the sync directory has it too. For
each changed sync directory:

- **Committed in the site repository:** the exported change is committed with
  the hotfix.
- **Inside a composer package** (for example an install profile): the change
  ships as `patches/security/<package>-config-<version>.patch`, listed under
  `extra.patches` in `composer.json`. A pull request with the same change is
  opened in the package's GitHub repository. Its branch is named after the
  change, so site repositories that need the same change share one pull request.
  Merge it before the site's next regular release, then remove the patch.

## Working with hotfixes

- **The source of each hotfix** is on `security/<version>` and on
  `refs/security/<version>`, which survives the branch being deleted and doesn't
  trigger tag-based CI. List them with `git ls-remote origin 'refs/security/*'`.
- **Don't delete `refs/security/*` for a version production runs.** The next
  run needs its source commit.
- **A run that finds a hotfix already built** for the same advisories on the
  same production tag stops. To rebuild, delete that version's ref
  (`git push origin :refs/security/<version>`); it isn't deployed.
- **Try changes with `dry-run`.** It builds the artifacts but pushes nothing,
  opens no pull requests and posts nothing to Slack.

## Scripts

All in `scripts/`; the workflow copies them out of the workspace before running.

| Script | Does |
|---|---|
| `find-production.sh` | Lists production tags and the git URLs that run them, as JSON. |
| `security-update.sh` | Audits `composer.lock` and updates the fewest packages. Safe to run locally on a copy of a `composer.json`/`composer.lock` pair. |
| `test-update.sh` | Installs, updates and exports test sites. **Don't run it locally:** it reinstalls sites and wipes their databases. |
| `config-pr.sh` | Opens the package config pull requests. |
| `lib.sh` | Shared helpers (reading `drush/drush.yml`, Slack escaping). |

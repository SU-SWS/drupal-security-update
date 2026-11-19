# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this repo is

A reusable GitHub Actions workflow (`.github/workflows/security-update.yml`, `on: workflow_call`)
plus the bash scripts it runs (`scripts/`). Drupal site repositories call it to build security
hotfixes of what their production runs on Acquia. `README.md` covers usage; the header of the
workflow describes each step.

## Working on it

- **Callers pin a ref.** They reference the workflow `@<ref>` and pass the same `tools-ref`, which
  the workflow uses to check out `scripts/`. Changing an input, output or secret name breaks
  callers. Add new inputs with defaults that keep the current behavior.
- **The scripts run against the caller's repository**, from its root. They read its
  `drush/drush.yml` through `drush_yml` in `scripts/lib.sh`, which uses Python's yaml module or
  falls back to `yq`.
- **The workflow copies `scripts/` to `/tmp/security-tools`** and removes the checkout, because
  `drush sws:artifact:deploy` refuses to build with untracked files.
- **Give new hotfix steps an `id`** and a line in `OUTCOMES` in "Notify Slack of a failure", so
  failures name them.
- **Test what you can locally:**
  - `security-update.sh` on a copy of a `composer.json`/`composer.lock` pair in a scratch
    directory.
  - `find-production.sh` with `PROD_REF` set.
  - `config-pr.sh` with a stub `gh` on `PATH` and `CLONE_URL_TEMPLATE` pointing at local bare
    repositories.
- **Don't run `test-update.sh` against a real site:** it reinstalls sites and drops their
  databases. Test the full workflow with a caller's `dry-run` input.
- **Check syntax** with `bash -n scripts/*.sh` and by parsing the workflow YAML.

## Git, commits and PRs

- Don't commit or push unless asked.
- Never add AI/Claude attribution to commit messages or PR descriptions. The commits and pull
  requests the workflow creates follow the same rule.

#!/usr/bin/env bash
#
# Open a pull request in each composer package whose config sync directory a
# security update's database updates changed, so the hotfix's config patch
# can be dropped once the package has the change.
#
# Usage: config-pr.sh <report-dir> <version> <acquia-tag>
#
# Runs from the site repository's root with the hotfix's composer.lock in
# place. Reads <report-dir>/config/*/ (from test-update.sh) and the other
# report files. Needs GH_TOKEN with contents and pull request write access to
# the packages' GitHub repositories. Appends "<package> <url>" lines to
# <report-dir>/config-prs.txt.
#
# The branch is named after the change itself (security-config/<hash>), so
# when several site repositories need the same change in a shared package,
# they share one pull request; later ones add a comment to it.
#
# Optional environment: PROD_TAG, RUN_URL, CLONE_URL_TEMPLATE (printf
# template for clone URLs, default https://github.com/%s.git; for testing).

set -euo pipefail

OUT="${1:?Usage: $0 <report-dir> <version> <acquia-tag>}"
VERSION="${2:?}"
TAG="${3:?}"
: "${GH_TOKEN:?GH_TOKEN must be set}"
SITE_REPO="${GITHUB_REPOSITORY:-this repository}"

for meta in "$OUT"/config/*/meta.json; do
  [[ -f "$meta" ]] || continue
  [[ "$(jq -r .mode "$meta")" == package ]] || continue
  cdir=$(dirname "$meta")
  package=$(jq -r .package "$meta")
  sync_dir=$(jq -r .sync_dir "$meta")
  patch_file=$(jq -r .patch_file "$meta")
  site=$(jq -r .site "$meta")
  patch="$cdir/config.patch"

  read -r locked_version locked_sha source_url < <(
    jq -r --arg p "$package" '(.packages + (.["packages-dev"] // []))[] | select(.name == $p) | "\(.version) \(.source.reference // "") \(.source.url // "")"' composer.lock
  )
  repo=$(sed -nE 's#^(https://github\.com/|git@github\.com:)([^/]+/[^/]+)$#\2#p' <<< "$source_url" | sed 's/\.git$//')
  if [[ -z "$repo" ]]; then
    echo "::warning::$package isn't hosted on GitHub ($source_url); open its pull request by hand from $(basename "$cdir")/config.patch in the report."
    continue
  fi
  # Locked to a branch (13.x-dev) or a release (12.0.3): target that branch,
  # or the release's major branch.
  case "$locked_version" in
    dev-*) base="${locked_version#dev-}" ;;
    *-dev) base="${locked_version%-dev}" ;;
    *) base="${locked_version%%.*}.x" ;;
  esac
  # Name the branch after the resulting files, not the patch, so the same
  # change made against different package versions still matches.
  fingerprint=$(grep -E '^(\+\+\+ |\+[^+]|-[^-])' "$patch" | sha256sum | cut -c1-10)
  branch="security-config/$fingerprint"
  echo "$package ($repo): locked to $locked_version, pull request against $base from $branch."

  existing=$(gh pr list -R "$repo" --head "$branch" --state open --json url --jq '.[0].url // empty')
  if [[ -n "$existing" ]]; then
    gh pr comment "$existing" --body "Also needed by \`$SITE_REPO\` for its \`$VERSION\` security update (\`$TAG\`)${RUN_URL:+: $RUN_URL}." > /dev/null
    echo "Commented on $existing"
    echo "$package $existing" >> "$OUT/config-prs.txt"
    continue
  fi

  dir=$(mktemp -d)
  # Authenticate this clone only, through gh and GH_TOKEN.
  git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    clone -q --filter=blob:none --no-tags --branch "$base" "$(printf "${CLONE_URL_TEMPLATE:-https://github.com/%s.git}" "$repo")" "$dir"
  git -C "$dir" config credential.helper ''
  git -C "$dir" config --add credential.helper '!gh auth git-credential'
  git -C "$dir" config user.name "GitHub Actions"
  git -C "$dir" config user.email "sws-developers@lists.stanford.edu"

  if git -C "$dir" apply --check -R -p1 "$patch" 2> /dev/null; then
    echo "$repo $base already has these config changes; no pull request needed."
    rm -rf "$dir"
    continue
  fi

  # Apply to the tip of the branch if possible. Otherwise branch from the
  # commit production runs, where the patch was made, and leave the conflicts
  # to the pull request.
  git -C "$dir" switch -q -c "$branch"
  based_on="the tip of \`$base\`"
  if ! git -C "$dir" apply --3way -p1 "$patch"; then
    echo "::warning::The $package config patch doesn't apply cleanly to $base; branching from the production commit instead."
    git -C "$dir" reset -q --hard
    git -C "$dir" cat-file -e "$locked_sha^{commit}" 2> /dev/null || git -C "$dir" fetch -q origin "$locked_sha"
    git -C "$dir" switch -q -C "$branch" "$locked_sha"
    git -C "$dir" apply -p1 "$patch"
    based_on="\`${locked_sha:0:10}\`, the commit production runs, because it conflicts with \`$base\`"
  fi
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "Config changes from database updates in a security update"
  git -C "$dir" push -q --force origin "HEAD:refs/heads/$branch"

  body="$cdir/pr-body.md"
  {
    echo "# READY FOR REVIEW"
    echo
    echo "# Summary"
    echo "- The database updates in \`$SITE_REPO\`'s \`$VERSION\` security update change configuration. This exports those changes to \`$(jq -r .rel_dir "$meta")\`, so \`drush deploy\` doesn't revert them."
    echo "- Until this is released, that hotfix ships the same change as \`$patch_file\`. Remove the patch from its \`composer.json\` once a release includes this."
    echo "- Built on $based_on."
    echo
    echo "# Review By (Date)"
    echo "- Before the next release from \`$base\`. A release without these changes reverts them on deploy."
    echo
    echo "# Urgency"
    echo "- High: security update."
    echo
    echo "# Review Tasks"
    echo
    echo "## Setup tasks and/or behavior to test"
    echo
    echo "1. Check that each change below comes from the module updates, not from the CI site's install."
    echo "2. Check out this branch, run the updates, then \`drush cr ; drush ci\` and confirm nothing is reverted."
    echo
    echo "### Site Configuration Sync"
    echo
    echo "Yes. Changed config (tested on the \`$site\` site of \`$SITE_REPO\`):"
    echo
    cat "$cdir/changes.md"
    echo
    echo "# Associated Issues and/or People"
    echo "- Production tag: \`${PROD_TAG:-unknown}\`; hotfix tag: \`$TAG\`"
    [[ -n "${RUN_URL:-}" ]] && echo "- Workflow run: $RUN_URL"
    echo
    echo "Advisories:"
    echo
    cat "$OUT/advisories.md"
    echo
    echo "Updated packages:"
    echo
    cat "$OUT/changes.md"
    if [[ -s "$OUT/db-updates.md" ]]; then
      echo
      echo "Database updates:"
      echo
      cat "$OUT/db-updates.md"
    fi
  } > "$body"

  url=$(gh pr create -R "$repo" --base "$base" --head "$branch" \
    --title "Config changes from database updates in a security update" \
    --body-file "$body")
  echo "Opened $url"
  echo "$package $url" >> "$OUT/config-prs.txt"
  rm -rf "$dir"
done

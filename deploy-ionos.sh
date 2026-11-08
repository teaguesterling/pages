#!/usr/bin/env bash
# Build the site for teaguesterling.com and sync it to its folder on the IONOS webspace.
#
# Usage:
#   ./deploy-ionos.sh         # DRY RUN: builds, then shows what rsync would change
#   ./deploy-ionos.sh --go    # builds and syncs
#
# The build uses the eleventy.config.js defaults (PATH_PREFIX "/", SITE_ORIGIN teaguesterling.com).
# update-stats.sh fetches fresh stats, releases and the Spack package list; it uses GITHUB_TOKEN, or `gh` when
# that is set up. Its Spack step shallow-clones spack and spack-packages unless SPACK_ROOT and SPACK_PACKAGES are
# set, so a deploy takes some minutes. The committed stats.json and spack.json are put back afterwards, so a
# deploy leaves the tree clean.
#
# Transport: IONOS is reachable only through snape, where its ssh alias `ionos` and key live
# (see ~/Projects/ionos/deploy/deploy.sh). The domain must point at DOCROOT in the IONOS panel.
set -euo pipefail

DOCROOT="sites/teaguesterling.com"
MODE="${1:-dry}"
cd "$(dirname "$0")"

backup=$(mktemp -d)
cp src/_data/stats.json src/_data/spack.json "$backup/"
trap 'cp "$backup"/*.json src/_data/; rm -rf "$backup"' EXIT

unset PATH_PREFIX SITE_ORIGIN
bash update-stats.sh
rm -rf _site
npx @11ty/eleventy

RSYNC=(rsync -rltvz --delete --omit-dir-times --no-perms -e "ssh snape ssh" _site/ "ionos:${DOCROOT}/")
if [ "$MODE" = "--go" ]; then
  echo ">> deploying _site -> ionos:${DOCROOT}"
  "${RSYNC[@]}"
else
  echo ">> DRY RUN _site -> ionos:${DOCROOT} (add --go to apply)"
  "${RSYNC[@]}" --dry-run
fi

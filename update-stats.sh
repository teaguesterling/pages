#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_FILE="$SCRIPT_DIR/projects.yaml"
OUTPUT_FILE="$SCRIPT_DIR/src/_data/stats.json"

if [[ ! -f "$YAML_FILE" ]]; then
  echo "Error: $YAML_FILE not found" >&2
  exit 1
fi

# Extract repo fields from YAML
repos=$(grep -oP '^\s+repo:\s+\K\S+' "$YAML_FILE" | sort -u)

echo "Fetching GitHub stars..."
stars_json="{"
first=true

# Build auth header if GITHUB_TOKEN is available (CI) or gh is installed (local)
auth_header=""
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  auth_header="Authorization: Bearer $GITHUB_TOKEN"
elif command -v gh &>/dev/null; then
  auth_header="Authorization: Bearer $(gh auth token 2>/dev/null || true)"
fi

for repo in $repos; do
  if [[ -n "$auth_header" ]]; then
    count=$(curl -s -H "$auth_header" "https://api.github.com/repos/$repo" 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('stargazers_count', 0))" 2>/dev/null || echo "0")
  else
    count=$(curl -s "https://api.github.com/repos/$repo" 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('stargazers_count', 0))" 2>/dev/null || echo "0")
  fi
  if [[ "$first" == true ]]; then first=false; else stars_json+=","; fi
  stars_json+="\"$repo\":$count"
  echo "  $repo: $count"
done
stars_json+="}"

echo ""
echo "Fetching recent releases..."
# One JSON array of each repo's last 5 published releases, for the Recent updates section and the feed.
# A repo with no releases returns []. Drafts aren't visible to this token, and prereleases are dropped.
releases_file=$(mktemp)
# The Spack clones go here, when SPACK_ROOT and SPACK_PACKAGES are unset (see the end of this script).
spack_tmp=$(mktemp -d)
trap 'rm -rf "$releases_file" "$spack_tmp"' EXIT
for repo in $repos; do
  if [[ -n "$auth_header" ]]; then
    curl -s -H "$auth_header" "https://api.github.com/repos/$repo/releases?per_page=5" 2>/dev/null
  else
    curl -s "https://api.github.com/repos/$repo/releases?per_page=5" 2>/dev/null
  fi | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    data = []
if not isinstance(data, list):
    data = []
for r in data:
    if r.get('draft') or r.get('prerelease') or not r.get('published_at'):
        continue
    print(json.dumps({'repo': sys.argv[1], 'tag': r['tag_name'], 'name': r.get('name') or r['tag_name'],
                      'published': r['published_at'], 'url': r['html_url']}))
" "$repo" >> "$releases_file" || true
done
echo "  $(wc -l < "$releases_file") releases"

echo ""
echo "Fetching DuckDB community extension downloads..."
downloads_json=$(curl -s "https://community-extensions.duckdb.org/downloads-last-week.json" 2>/dev/null || echo "{}")

# Combine into stats.json
mkdir -p "$(dirname "$OUTPUT_FILE")"
python3 -c "
import json, sys

stars = json.loads(sys.argv[1])
downloads = json.loads(sys.argv[2])
with open(sys.argv[4]) as f:
    releases = sorted((json.loads(line) for line in f if line.strip()), key=lambda r: r['published'], reverse=True)

# Map repo names to community extension names
# The community registry uses short names without the duckdb_ prefix in most cases
extension_name_map = {
    'teaguesterling/duckdb_webbed': 'webbed',
    'teaguesterling/duckdb_markdown': 'markdown',
    'teaguesterling/duckdb_yaml': 'yaml',
    'teaguesterling/duckdb_duck_block_utils': 'duck_block_utils',
    'teaguesterling/duckdb_read_lines': 'read_lines',
    'teaguesterling/sitting_duck': 'sitting_duck',
    'teaguesterling/duck_hunt': 'duck_hunt',
    'teaguesterling/duck_tails': 'duck_tails',
    'teaguesterling/duckdb_urlpattern': 'urlpattern',
    'teaguesterling/duckdb_scalarfs': 'scalarfs',
    'teaguesterling/duckdb_mcp': 'duckdb_mcp',
    'teaguesterling/duckdb_func_apply': 'func_apply',
    'teaguesterling/geneducks': 'geneducks',
    'teaguesterling/fledgling': 'fledgling',
    'teaguesterling/plinking_duck': 'plinking_duck',
    'teaguesterling/duckdb_extension_parser_tools': 'parser_tools',
    'teaguesterling/duckdb_zim': 'zim',
    'teaguesterling/duckdb_panduck': 'panduck',
}

repo_downloads = {}
for repo, ext_name in extension_name_map.items():
    if ext_name in downloads:
        repo_downloads[repo] = downloads[ext_name]

stats = {
    'stars': stars,
    'downloads_weekly': repo_downloads,
    'downloads_source': 'community-extensions.duckdb.org',
    'last_updated': downloads.get('_last_update', ''),
    'releases': releases,
}

with open(sys.argv[3], 'w') as f:
    json.dump(stats, f, indent=2)

print(f'Wrote stats for {len(stars)} repos ({len(repo_downloads)} with download data)')
" "$stars_json" "$downloads_json" "$OUTPUT_FILE" "$releases_file"

echo ""
echo "Building the Spack package manifest..."
# scripts/spack-manifest.py lists the Spack packages I maintain into src/_data/spack.json. It needs a spack/spack
# and a spack/spack-packages checkout: SPACK_ROOT and SPACK_PACKAGES, or shallow clones made here.
# A failure keeps the committed spack.json, so Spack or the GitHub API being down does not stop a deploy.
# (errexit does not apply inside a function called as an `if` condition, so each step checks its own status.)
spack_manifest() {
  local spack_root="${SPACK_ROOT:-}" spack_packages="${SPACK_PACKAGES:-}"
  if [[ -z "$spack_root" ]]; then
    spack_root="$spack_tmp/spack"
    git clone -q --depth 1 https://github.com/spack/spack "$spack_root" || return 1
  fi
  if [[ -z "$spack_packages" ]]; then
    spack_packages="$spack_tmp/spack-packages"
    git clone -q --depth 1 https://github.com/spack/spack-packages "$spack_packages" || return 1
  fi
  SPACK_ROOT="$spack_root" SPACK_PACKAGES="$spack_packages" python3 "$SCRIPT_DIR/scripts/spack-manifest.py" || return 1
}
# It takes minutes, so in GitHub Actions it runs only when the workflow sets SPACK_MANIFEST=1 (the daily
# schedule and manual runs). Push deploys use the spack.json that the last scheduled run left in the cache.
if [[ -n "${GITHUB_ACTIONS:-}" && "${SPACK_MANIFEST:-0}" != "1" ]]; then
  echo "Skipped (SPACK_MANIFEST is not 1); using src/_data/spack.json as it is"
elif ! spack_manifest; then
  echo "Warning: the Spack manifest failed; keeping the previous src/_data/spack.json" >&2
fi

echo "Done. Output: $OUTPUT_FILE"

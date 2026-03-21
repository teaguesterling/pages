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
echo "Fetching DuckDB community extension downloads..."
downloads_json=$(curl -s "https://community-extensions.duckdb.org/downloads-last-week.json" 2>/dev/null || echo "{}")

# Combine into stats.json
mkdir -p "$(dirname "$OUTPUT_FILE")"
python3 -c "
import json, sys

stars = json.loads(sys.argv[1])
downloads = json.loads(sys.argv[2])

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
}

with open(sys.argv[3], 'w') as f:
    json.dump(stats, f, indent=2)

print(f'Wrote stats for {len(stars)} repos ({len(repo_downloads)} with download data)')
" "$stars_json" "$downloads_json" "$OUTPUT_FILE"

echo "Done. Output: $OUTPUT_FILE"

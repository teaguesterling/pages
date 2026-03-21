#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_FILE="$SCRIPT_DIR/projects-flat.yaml"
OUTPUT_FILE="$SCRIPT_DIR/issues.json"

if [[ ! -f "$YAML_FILE" ]]; then
  echo "Error: $YAML_FILE not found" >&2
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "Error: gh CLI not found. Install it from https://cli.github.com/" >&2
  exit 1
fi

# Extract repo fields from YAML (lines matching "repo: owner/name")
repos=$(grep -oP '^\s+repo:\s+\K\S+' "$YAML_FILE")

echo "Found repos:"
echo "$repos"
echo ""

# Collect all issues into a temp file as JSON arrays, then merge
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fields="number,title,state,createdAt,updatedAt,labels,url,author,assignees"
count=0

for repo in $repos; do
  echo "Fetching issues for $repo ..."
  outfile="$tmp_dir/$(echo "$repo" | tr '/' '_').json"

  if gh issue list \
      --repo "$repo" \
      --state open \
      --limit 500 \
      --json "$fields" \
      > "$outfile" 2>/dev/null; then

    # Check if we got any issues
    issue_count=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(len(d))" "$outfile" 2>/dev/null || echo "0")
    echo "  -> $issue_count open issues"

    if [[ "$issue_count" -gt 0 ]]; then
      # Add repo field to each issue
      python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    issues = json.load(f)
for issue in issues:
    issue['repo'] = sys.argv[2]
with open(sys.argv[1], 'w') as f:
    json.dump(issues, f)
" "$outfile" "$repo"
      count=$((count + 1))
    else
      rm -f "$outfile"
    fi
  else
    echo "  -> Failed to fetch (repo may not exist or no access)" >&2
    rm -f "$outfile"
  fi
done

# Merge all JSON arrays into one
python3 -c "
import json, glob, sys, os

all_issues = []
pattern = os.path.join(sys.argv[1], '*.json')
for path in sorted(glob.glob(pattern)):
    with open(path) as f:
        all_issues.extend(json.load(f))

# Sort by updatedAt descending
all_issues.sort(key=lambda x: x.get('updatedAt', ''), reverse=True)

with open(sys.argv[2], 'w') as f:
    json.dump(all_issues, f, indent=2)

print(f'Wrote {len(all_issues)} issues to {sys.argv[2]}')
" "$tmp_dir" "$OUTPUT_FILE"

echo "Done. Output: $OUTPUT_FILE"

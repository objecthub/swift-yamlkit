#!/bin/bash
#
# Generates the static DocC website and prepares it for publishing with GitHub Pages.
#
# The site is served from the root of the `gh-pages` branch at
# https://objecthub.github.io/swift-yamlkit/. This script builds the site with
# Scripts/build-documentation.sh and copies it into a git worktree of branch `gh-pages`
# (in `.build/gh-pages`, which git ignores). It does not commit or push anything.
# To publish the result:
#
#   cd .build/gh-pages
#   git add -A
#   git commit -m "Update the documentation site"
#   git push -u origin gh-pages
#
# Run this script before a release: the site documents the current working copy.
#
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SITE="$ROOT/.build/docs-site"
WORKTREE="$ROOT/.build/gh-pages"
BRANCH="gh-pages"

# 1. Generate the site
Scripts/build-documentation.sh site swift-yamlkit

# 2. DocC does not generate a page for the root of the site; redirect it to the documentation
cat > "$SITE/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>YamlKit Documentation</title>
  <meta http-equiv="refresh" content="0; url=documentation/yamlkit/">
  <link rel="canonical" href="documentation/yamlkit/">
</head>
<body>
  <p>Redirecting to the <a href="documentation/yamlkit/">YamlKit documentation</a>&hellip;</p>
</body>
</html>
HTML

# 3. Serve the files as they are, without any Jekyll processing
touch "$SITE/.nojekyll"

# 4. Sort the keys of DocC's JSON files (which does not change their meaning), so that
#    regenerating the site only changes files whose content changed
python3 -I - "$SITE" <<'PYTHON'
import json, os, sys
for directory, _, names in os.walk(sys.argv[1]):
    for name in names:
        if name.endswith(".json"):
            path = os.path.join(directory, name)
            with open(path, encoding="utf-8") as file:
                data = json.load(file)
            with open(path, "w", encoding="utf-8") as file:
                json.dump(data, file, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
PYTHON

# 5. Make sure there is a worktree for the `gh-pages` branch
git worktree prune
if [ ! -e "$WORKTREE/.git" ]; then
  rm -rf "$WORKTREE"
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git worktree add "$WORKTREE" "$BRANCH"
  elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    git worktree add -b "$BRANCH" "$WORKTREE" "origin/$BRANCH"
  else
    # The branch does not exist yet; create it without any history (requires git 2.42)
    git worktree add --orphan -b "$BRANCH" "$WORKTREE"
  fi
fi

# 6. Replace the contents of the worktree with the new site (keeping the worktree's .git file)
rsync -a --delete --exclude '/.git' "$SITE/" "$WORKTREE/"

echo
echo "The documentation site is ready in .build/gh-pages. To publish it:"
echo "  cd .build/gh-pages && git add -A && git commit -m \"Update the documentation site\" && git push -u origin gh-pages"

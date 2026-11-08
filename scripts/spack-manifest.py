#!/usr/bin/env python3
"""Write src/_data/spack.json: the Spack packages that the site owner maintains.

The site's "Spack packages" area renders the rows in that file. The script finds the packages
with Spack itself, because a recipe can inherit its maintainers from a base class:

1. ``spack maintainers --by-user <user>`` over a spack/spack-packages checkout gives the merged set.
2. Each open pull request by the user that adds a package.py is checked out in a git worktree,
   and the same command runs there. The packages that are not in the merged set are "open",
   with the lowest pull request number that adds them.
3. Each recipe gives a description (the first sentence of the class docstring) and an upstream
   GitHub repository (from homepage, git or url).
4. ``categories.spack_packages`` in projects.yaml supplies the groups (one row for many packages),
   the per-package overrides, and the rows to show first.

Environment:
  SPACK_ROOT      a spack/spack checkout (required)
  SPACK_PACKAGES  a spack/spack-packages checkout (required)
  GITHUB_TOKEN    GitHub API token; if unset, the output of ``gh auth token`` is used

The script uses only the Python standard library, and the YAML parser vendored in the Spack checkout.
It exits non-zero, and does not touch the output file, when any step fails or Spack finds no package.
"""

import argparse
import ast
import datetime
import json
import keyword
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

PACKAGES_URL = "https://github.com/spack/spack-packages"
PACKAGES_API = "https://api.github.com/repos/spack/spack-packages"
PACKAGE_PAGE = "https://packages.spack.io/package.html?name={}"
RECIPE_DIR = Path("repos/spack_repo/builtin/packages")
GITHUB_REPO = re.compile(r"https?://github\.com/([\w.-]+)/([\w.-]+?)(?:\.git)?(?:[/#?]|$)")


class ManifestError(Exception):
    pass


def log(message):
    print(message, file=sys.stderr, flush=True)


def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        raise ManifestError(f"{' '.join(map(str, args))} failed ({result.returncode}):\n{result.stderr.strip()}")
    return result.stdout


def load_yaml(spack_root, path):
    """Loads a YAML file with the ruamel.yaml that Spack vendors, so no pip package is needed."""
    sys.path.insert(0, str(Path(spack_root) / "lib" / "spack"))
    try:
        from spack.vendor.ruamel.yaml import YAML
    except ImportError as e:
        raise ManifestError(f"SPACK_ROOT={spack_root} is not a Spack 1.x checkout: {e}") from e

    with open(path) as f:
        return YAML(typ="safe").load(f)


# --- Spack ---------------------------------------------------------------------------------------


def maintained(spack_root, packages_root, user, workdir, label):
    """Returns the names that ``spack maintainers --by-user`` lists for user, with the builtin repo
    at packages_root. The local config of the person who runs this is not read, and each checkout
    gets its own cache, so an index made for one checkout does not serve another."""
    scope = Path(workdir) / f"scope-{label}"
    scope.mkdir()
    builtin = (Path(packages_root) / RECIPE_DIR).parent
    (scope / "repos.yaml").write_text(f"repos::\n  builtin: {json.dumps(str(builtin))}\n")
    env = dict(
        os.environ,
        SPACK_DISABLE_LOCAL_CONFIG="1",
        SPACK_USER_CONFIG_PATH=str(Path(workdir) / "user-config"),
        SPACK_USER_CACHE_PATH=str(Path(workdir) / f"cache-{label}"),
    )
    spack = Path(spack_root) / "bin" / "spack"
    args = [sys.executable, spack, "-C", scope, "maintainers", "--by-user", user]
    result = subprocess.run(args, capture_output=True, text=True, env=env)
    if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():
        return set()  # Spack exits 1, silently, for a user who maintains no package
    if result.returncode != 0:
        raise ManifestError(f"{' '.join(map(str, args))} failed ({result.returncode}):\n{result.stderr.strip()}")
    return set(result.stdout.split())


def recipe_dir(name):
    """The directory of a package in a Spack v2 repository (spack.util.naming.pkg_name_to_pkg_dir)."""
    d = name.replace("-", "_")
    return f"_{d}" if d[0].isdigit() or keyword.iskeyword(d) else d


def recipe_class(name):
    """The class name of a package (spack.util.naming.pkg_name_to_class_name)."""
    c = "".join(part.capitalize() for part in re.split(r"[-_]+", name))
    return f"_{c}" if c[0].isdigit() else c


def read_recipe(packages_root, name):
    """Returns (text, description, homepage, upstream) from a package.py."""
    path = Path(packages_root) / RECIPE_DIR / recipe_dir(name) / "package.py"
    text = path.read_text()
    classes = [n for n in ast.parse(text).body if isinstance(n, ast.ClassDef)]
    cls = next((c for c in classes if c.name == recipe_class(name)), None)
    if cls is None:
        raise ManifestError(f"{path}: no class {recipe_class(name)}")
    attrs = {}
    for node in cls.body:
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant):
            for target in node.targets:
                if isinstance(target, ast.Name) and isinstance(node.value.value, str):
                    attrs[target.id] = node.value.value
    doc = " ".join((ast.get_docstring(cls) or "").split())
    description = re.split(r"(?<=[.!?])\s", doc, maxsplit=1)[0].rstrip(".")
    upstream = None
    for key in ("homepage", "git", "url"):
        m = GITHUB_REPO.match(attrs.get(key, ""))
        if m:
            upstream = f"{m.group(1)}/{m.group(2)}"
            break
    return text, description, attrs.get("homepage"), upstream


# --- GitHub --------------------------------------------------------------------------------------


def github_token():
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        return token
    try:
        return subprocess.run(["gh", "auth", "token"], capture_output=True, text=True).stdout.strip() or None
    except FileNotFoundError:
        return None


def github(url, token):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "teaguesterling-pages"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
            return json.load(r)
    except OSError as e:
        raise ManifestError(f"GitHub API {url}: {e}") from e


def github_pages(url, token, key=None):
    """All items of a paginated GitHub list (or of the `key` list of a search result)."""
    items, page = [], 1
    while True:
        sep = "&" if "?" in url else "?"
        data = github(f"{url}{sep}per_page=100&page={page}", token)
        batch = data[key] if key else data
        items.extend(batch)
        if len(batch) < 100:
            return items
        page += 1


def open_prs(user, token):
    """The numbers of the user's open pull requests, lowest first, each with the package names
    whose package.py it adds (the directory names, which recipe_dir() maps from names)."""
    q = urllib.parse.quote(f"repo:spack/spack-packages is:pr is:open author:{user}")
    numbers = sorted(i["number"] for i in github_pages(f"https://api.github.com/search/issues?q={q}", token, "items"))
    prs = []
    for n in numbers:
        files = github_pages(f"{PACKAGES_API}/pulls/{n}/files", token)
        added = {
            Path(f["filename"]).parent.name
            for f in files
            if f["status"] == "added" and f["filename"].startswith(f"{RECIPE_DIR}/") and f["filename"].endswith("/package.py")
        }
        prs.append((n, added))
    return numbers, prs


# --- Rows ----------------------------------------------------------------------------------------


def pr_note(prs):
    return "In spack/spack-packages" + ", ".join(f"#{n}" for n in sorted(prs)) + " (open)"


def build_rows(packages, config):
    """packages: name -> dict(description, upstream, text, pr). Returns the rows for spack.json."""
    groups = config.get("groups") or []
    overrides = config.get("overrides") or {}
    members = {g["id"]: [] for g in groups}
    singles = []
    for name in sorted(packages):
        p = packages[name]
        for g in groups:
            if name in (g.get("members") or []) or (
                re.search(g["match"], name) and re.search(g.get("recipe_match", ""), p["text"])
            ):
                members[g["id"]].append(name)
                break
        else:
            singles.append(name)

    rows = []
    for g in groups:
        names = members[g["id"]]
        if not names:
            continue
        open_prs_ = {packages[n]["pr"] for n in names if packages[n]["pr"]}
        notes = []
        if open_prs_:
            n_open = sum(1 for n in names if packages[n]["pr"])
            prefix = "" if n_open == len(names) else f"{n_open} of {len(names)} "
            notes.append(prefix + pr_note(open_prs_))
        if g.get("note"):
            notes.append(g["note"])
        page = g.get("spack_package")
        rows.append(
            {
                "id": g["id"],
                "name": g["name"],
                "description": g["description"],
                "spack_url": PACKAGE_PAGE.format(page) if page in packages and not packages[page]["pr"] else None,
                "upstream": g.get("upstream"),
                "features": names,
                "note": "; ".join(notes) or None,
            }
        )
    for name in singles:
        p, o = packages[name], overrides.get(name) or {}
        rows.append(
            {
                "id": f"spack-{name}",
                "name": name,
                "description": o.get("description", p["description"]),
                "spack_url": None if p["pr"] else PACKAGE_PAGE.format(name),
                "upstream": o["upstream"] if "upstream" in o else p["upstream"],
                "features": None,
                "note": pr_note([p["pr"]]) if p["pr"] else None,
            }
        )
    first = config.get("first") or []
    rows.sort(key=lambda r: (first.index(r["id"]) if r["id"] in first else len(first), r["name"]))
    return [{k: v for k, v in r.items() if v is not None} for r in rows]


# --- Main ----------------------------------------------------------------------------------------


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--projects", default=repo / "projects.yaml", type=Path)
    parser.add_argument("--output", default=repo / "src" / "_data" / "spack.json", type=Path)
    args = parser.parse_args()

    spack_root, packages_root = os.environ.get("SPACK_ROOT"), os.environ.get("SPACK_PACKAGES")
    if not spack_root or not packages_root:
        raise ManifestError("set SPACK_ROOT to a spack/spack checkout and SPACK_PACKAGES to a spack/spack-packages checkout")
    start = time.monotonic()
    projects = load_yaml(spack_root, args.projects)
    user = projects["site"]["github_username"]
    config = projects["categories"]["spack_packages"]
    token = github_token()

    packages = {}  # name -> dict(description, upstream, text, pr)

    def add(root, names, pr):
        for name in sorted(names):
            text, description, _, upstream = read_recipe(root, name)
            packages[name] = {"text": text, "description": description, "upstream": upstream, "pr": pr}

    with tempfile.TemporaryDirectory(prefix="spack-manifest-") as workdir:
        merged = maintained(spack_root, packages_root, user, workdir, "merged")
        if not merged:
            raise ManifestError(f"spack maintainers --by-user {user} listed no package; refusing to write an empty manifest")
        log(f"merged: {len(merged)} packages maintained by {user}")
        add(packages_root, merged, None)

        numbers, prs = open_prs(user, token)
        log(f"open pull requests by {user}: {len(numbers)}; {sum(1 for _, a in prs if a)} add a package.py")
        # Skip a pull request that adds nothing, or only directories that are merged or that a lower pull
        # request adds (stacked pull requests repeat the files of the ones below them).
        seen, todo = {recipe_dir(p) for p in merged}, []
        for n, added in prs:
            if added - seen:
                todo.append(n)
            seen |= added
        trees = {}
        try:
            for n in todo:  # git commands one at a time: they share the checkout's locks
                trees[n] = Path(workdir) / f"pr-{n}"
                run(["git", "-C", packages_root, "fetch", "-q", "--depth", "1", PACKAGES_URL, f"pull/{n}/head"])
                run(["git", "-C", packages_root, "worktree", "add", "-q", "--detach", trees[n], "FETCH_HEAD"])
            # Spack loads every recipe of a new checkout and builds its indexes, which takes most of a minute.
            # Run a few at once: the work is mostly disk, so more at once was slower on a busy machine.
            with ThreadPoolExecutor(max_workers=4) as pool:
                found = dict(zip(todo, pool.map(lambda n: maintained(spack_root, trees[n], user, workdir, f"pr-{n}"), todo)))
            for n in todo:  # lowest number first, so a package keeps the lowest pull request that adds it
                new = found[n] - set(packages)
                log(f"  #{n}: {len(new)} new: {' '.join(sorted(new))}")
                add(trees[n], new, n)
        finally:
            for tree in trees.values():
                subprocess.run(["git", "-C", packages_root, "worktree", "remove", "--force", tree], capture_output=True)
            subprocess.run(["git", "-C", packages_root, "worktree", "prune"], capture_output=True)

    rows = build_rows(packages, config)
    manifest = {
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "spack_commit": run(["git", "-C", spack_root, "rev-parse", "HEAD"]).strip(),
        "spack_packages_commit": run(["git", "-C", packages_root, "rev-parse", "HEAD"]).strip(),
        "user": user,
        "merged_count": len(merged),
        "open_count": len(packages) - len(merged),
        "rows": rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    tmp = args.output.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(manifest, indent=2) + "\n")
    os.replace(tmp, args.output)
    log(f"wrote {args.output}: {len(rows)} rows, {len(packages)} packages ({len(merged)} merged), {time.monotonic() - start:.0f}s")


if __name__ == "__main__":
    try:
        main()
    except ManifestError as e:
        log(f"spack-manifest: {e}")
        sys.exit(1)

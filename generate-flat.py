#!/usr/bin/env python3
"""Generate projects-flat.yaml from the hierarchical projects.yaml."""

import yaml
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
INPUT = SCRIPT_DIR / "projects.yaml"
OUTPUT = SCRIPT_DIR / "projects-flat.yaml"


def flatten_projects(data):
    """Extract all projects from the hierarchical category structure."""
    projects = []
    categories = data.get("categories", {})

    for cat_key, category in categories.items():
        cat_title = category.get("title", cat_key)

        # Categories with subcategories (like duckdb_extensions)
        if "subcategories" in category:
            for sub_key, subcategory in category["subcategories"].items():
                sub_title = subcategory.get("title", sub_key)
                for project in subcategory.get("projects", []):
                    entry = dict(project)
                    entry["category"] = cat_title
                    entry["subcategory"] = sub_title
                    projects.append(entry)

        # Categories with direct projects list
        if "projects" in category:
            for project in category["projects"]:
                entry = dict(project)
                entry["category"] = cat_title
                projects.append(entry)

    return projects


class CleanDumper(yaml.SafeDumper):
    """YAML dumper that avoids unnecessary quotes and uses flow style for short lists."""
    pass


def str_representer(dumper, data):
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="")


def list_representer(dumper, data):
    # Use flow style for short lists of simple strings (like badges)
    if all(isinstance(item, str) and len(item) < 20 for item in data) and len(data) <= 5:
        return dumper.represent_sequence("tag:yaml.org,2002:seq", data, flow_style=True)
    return dumper.represent_sequence("tag:yaml.org,2002:seq", data, flow_style=False)


CleanDumper.add_representer(str, str_representer)
CleanDumper.add_representer(list, list_representer)


# Preserve key ordering
PROJECT_KEY_ORDER = [
    "id", "name", "category", "subcategory", "repo", "upstream", "url",
    "description", "features", "badges", "docs_url", "role", "institution",
    "note", "status",
]


def ordered_project(project):
    """Return project dict with keys in a consistent order."""
    ordered = {}
    for key in PROJECT_KEY_ORDER:
        if key in project:
            ordered[key] = project[key]
    # Any remaining keys not in the order list
    for key in project:
        if key not in ordered:
            ordered[key] = project[key]
    return ordered


def group_comment(project):
    """Generate a section comment based on category/subcategory."""
    parts = [project["category"]]
    if "subcategory" in project:
        parts.append(project["subcategory"])
    return " - ".join(parts)


def main():
    with open(INPUT) as f:
        data = yaml.safe_load(f)

    projects = flatten_projects(data)
    projects = [ordered_project(p) for p in projects]

    # Build output manually for comments between sections
    lines = [
        "# Portfolio Projects - Flat Format",
        "# Generated from projects.yaml — do not edit directly",
        "# Run: python3 generate-flat.py",
        "",
        "site:",
    ]

    site = data.get("site", {})
    for key, value in site.items():
        lines.append(f"  {key}: {value}")

    lines.append("")
    lines.append("projects:")

    current_group = None
    for project in projects:
        new_group = group_comment(project)
        if new_group != current_group:
            lines.append(f"  # {new_group}")
            current_group = new_group

        # Dump single project as YAML, then indent it as a list item
        proj_yaml = yaml.dump(
            project,
            Dumper=CleanDumper,
            default_flow_style=False,
            sort_keys=False,
            allow_unicode=True,
            width=120,
        ).rstrip()

        proj_lines = proj_yaml.split("\n")
        lines.append(f"  - {proj_lines[0]}")
        for pl in proj_lines[1:]:
            lines.append(f"    {pl}")
        lines.append("")

    output = "\n".join(lines)

    with open(OUTPUT, "w") as f:
        f.write(output)

    print(f"Generated {OUTPUT} with {len(projects)} projects")


if __name__ == "__main__":
    main()

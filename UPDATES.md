# Recent updates

The index's "Recent updates" section (the newest 5), the `/updates/` page (the newest 50) and `feed.xml` (Atom) read one list, built by the `recentUpdates` filter in
`eleventy.config.js`:

- **Releases** of the DuckDB extensions come from GitHub. `update-stats.sh` fetches each repo's last 5 releases into
  `src/_data/stats.json` at deploy. `deploy.yml` also runs daily, so a release shows up within a day with nothing to
  edit by hand.
- **Notes** are hand-written, for a change a version number can't explain. Add `src/updates/YYYY-MM-DD-slug.md`:

  ```markdown
  ---
  title: "webbed reads TIMESTAMPTZ the way read_csv does"
  project: webbed
  summary: "One sentence for the index and the feed."
  ---
  A few short paragraphs. Link the release and the docs for the detail.
  ```

  The date comes from the file name. Keep links through the `url` filter, not a hard-coded `/pages/`, so the
  site can move to a custom domain by changing `pathPrefix` and `site.origin` in `projects.yaml`.

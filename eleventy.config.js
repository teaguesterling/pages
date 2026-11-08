import yaml from "js-yaml";

// The site's host. The defaults are teaguesterling.com, the custom domain GitHub Pages serves this repo on.
// Set both variables to build for another host, such as PATH_PREFIX=/pages/ for teaguesterling.github.io/pages/.
const PATH_PREFIX = process.env.PATH_PREFIX || "/";
const SITE_ORIGIN = process.env.SITE_ORIGIN || "https://teaguesterling.com";

export default function (eleventyConfig) {
  // The scheme and host, without the path prefix. With the `url` filter it makes the feed's absolute URLs.
  eleventyConfig.addGlobalData("siteOrigin", SITE_ORIGIN);

  // Add YAML support for data files
  eleventyConfig.addDataExtension("yaml,yml", (contents) =>
    yaml.load(contents)
  );

  // Copy static assets
  eleventyConfig.addPassthroughCopy("src/css");
  eleventyConfig.addPassthroughCopy("src/assets");
  eleventyConfig.addPassthroughCopy({ "static": "static" });

  // Helper to generate badge URL
  eleventyConfig.addFilter("badgeUrl", function (repo, type, badges, workflow) {
    const config = badges[type];
    if (!config) return "";
    return config.template
      .replace("{repo}", repo)
      .replace("{workflow}", workflow || config.default_workflow || "");
  });

  // Helper to generate badge link
  eleventyConfig.addFilter("badgeLink", function (repo, type, badges) {
    const config = badges[type];
    if (!config || !config.link_template) return `https://github.com/${repo}`;
    return config.link_template.replace("{repo}", repo);
  });

  // Flatten projects from subcategories
  eleventyConfig.addFilter("flattenProjects", function (subcategories) {
    if (!subcategories) return [];
    return Object.values(subcategories).flatMap((sub) => sub.projects || []);
  });

  // Count the projects in a list of category keys, through subcategories too. The index's area cards use it.
  // The spack_packages rows come from src/_data/spack.json (scripts/spack-manifest.py), as in category-section.njk.
  eleventyConfig.addFilter("countProjects", function (keys, categories) {
    return (keys || []).reduce((n, key) => {
      const c = categories?.[key] || {};
      const rows = key === "spack_packages" ? this.ctx?.spack?.rows : c.projects;
      return n + (rows || Object.values(c.subcategories || {}).flatMap((sub) => sub.projects || [])).length;
    }, 0);
  });

  // Look up stars for a repo
  eleventyConfig.addFilter("stars", function (repo) {
    const stats = this.ctx?.stats;
    if (!stats?.stars) return null;
    return stats.stars[repo] ?? null;
  });

  // Look up weekly downloads for a repo
  eleventyConfig.addFilter("downloads", function (repo) {
    const stats = this.ctx?.stats;
    if (!stats?.downloads_weekly) return null;
    return stats.downloads_weekly[repo] ?? null;
  });

  // Format numbers with K suffix
  eleventyConfig.addFilter("compactNumber", function (num) {
    if (num == null) return "";
    if (num >= 1000) return (num / 1000).toFixed(1).replace(/\.0$/, "") + "k";
    return num.toString();
  });

  // Recent updates: the DuckDB extensions' GitHub releases (fetched into stats.json by update-stats.sh) merged with
  // the hand-written notes in src/updates/, newest first. The index section and feed.xml both read this list.
  // `grouped` (the index) shows each extension once, at its newest release, and lists its other releases from the
  // 14 days before that in `earlier`. The feed keeps one entry per release, so an entry never changes once read.
  eleventyConfig.addFilter("recentUpdates", function (notes, limit, grouped) {
    const extensions = new Map();
    const subcategories = this.ctx?.projects?.categories?.duckdb_extensions?.subcategories || {};
    for (const sub of Object.values(subcategories)) {
      for (const p of sub.projects || []) extensions.set(p.repo, p.name);
    }
    const releases = (this.ctx?.stats?.releases || [])
      .filter((r) => extensions.has(r.repo))
      .map((r) => ({
        kind: "release",
        project: extensions.get(r.repo),
        title: `${extensions.get(r.repo)} ${r.tag}`,
        tag: r.tag,
        date: new Date(r.published),
        url: r.url,
        earlier: [],
      }))
      .sort((a, b) => b.date - a.date);
    if (grouped) {
      const GROUP_DAYS = 14;
      const newest = new Map();
      for (const r of releases) {
        const head = newest.get(r.project);
        if (!head) {
          newest.set(r.project, r);
        } else if (head.date - r.date <= GROUP_DAYS * 86400000) {
          head.earlier.push({ tag: r.tag, url: r.url });
        }
      }
      releases.splice(0, releases.length, ...newest.values());
    }
    const written = (notes || []).map((n) => ({
      kind: "note",
      project: n.data.project || "",
      title: n.data.title,
      summary: n.data.summary || "",
      date: n.date,
      url: n.url,
      // A getter, so only the feed reads a note's rendered content, after the note has rendered.
      get content() {
        return n.content;
      },
    }));
    return [...written, ...releases].sort((a, b) => b.date - a.date).slice(0, limit || 10);
  });

  eleventyConfig.addFilter("isoDate", (date) => new Date(date).toISOString());
  eleventyConfig.addFilter("shortDate", (date) => new Date(date).toISOString().slice(0, 10));

  return {
    pathPrefix: PATH_PREFIX,
    dir: {
      input: "src",
      output: "_site",
      includes: "_includes",
      data: "_data",
    },
    templateFormats: ["njk", "md", "html"],
    htmlTemplateEngine: "njk",
    markdownTemplateEngine: "njk",
  };
}

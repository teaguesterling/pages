import yaml from "js-yaml";

export default function (eleventyConfig) {
  // Add YAML support for data files
  eleventyConfig.addDataExtension("yaml,yml", (contents) =>
    yaml.load(contents)
  );

  // Copy static assets
  eleventyConfig.addPassthroughCopy("src/css");
  eleventyConfig.addPassthroughCopy("src/assets");
  eleventyConfig.addPassthroughCopy({ "static": "static" });

  // Helper to generate badge URL
  eleventyConfig.addFilter("badgeUrl", function (repo, type, badges) {
    const config = badges[type];
    if (!config) return "";
    return config.template
      .replace("{repo}", repo)
      .replace("{workflow}", config.default_workflow || "");
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

  return {
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

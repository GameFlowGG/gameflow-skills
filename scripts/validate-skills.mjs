#!/usr/bin/env node
// Validates every skills/<name>/SKILL.md against the Agent Skills spec
// (https://agentskills.io/specification) plus repo conventions:
//   - frontmatter has name + description; name matches the directory and is
//     lowercase-hyphenated, 1-64 chars, no leading/trailing/double hyphens
//   - description is 1-1024 chars
//   - SKILL.md body is under 500 lines
//   - every relative markdown link in a skill resolves to a file
//   - no file looks like it contains a real GameFlow API key
// Zero dependencies. Exit code 1 on any failure.
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, dirname, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const skillsDir = join(root, "skills");
const errors = [];
const fail = (file, msg) => errors.push(`${relative(root, file)}: ${msg}`);

function walk(dir) {
  return readdirSync(dir).flatMap((entry) => {
    const p = join(dir, entry);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

function parseFrontmatter(text) {
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/);
  if (!m) return null;
  const fields = {};
  for (const line of m[1].split(/\r?\n/)) {
    const kv = line.match(/^([a-zA-Z-]+):\s*(.*)$/);
    if (kv) fields[kv[1]] = kv[2].replace(/^["']|["']$/g, "");
  }
  return { fields, bodyStart: m[0].length };
}

const NAME_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
// Real keys are gf_ + 32 hex chars; placeholders like gf_xxxx or gf_... are fine.
const KEY_RE = /\bgf_[0-9a-f]{32}\b/;

const skillNames = readdirSync(skillsDir).filter((d) => statSync(join(skillsDir, d)).isDirectory());
if (skillNames.length === 0) fail(skillsDir, "no skills found");

for (const name of skillNames) {
  const dir = join(skillsDir, name);
  const skillFile = join(dir, "SKILL.md");
  if (!existsSync(skillFile)) {
    fail(dir, "missing SKILL.md");
    continue;
  }
  const text = readFileSync(skillFile, "utf8");
  const fm = parseFrontmatter(text);
  if (!fm) {
    fail(skillFile, "missing YAML frontmatter");
    continue;
  }
  const { name: fmName, description } = fm.fields;
  if (!fmName) fail(skillFile, "frontmatter missing `name`");
  else {
    if (fmName !== name) fail(skillFile, `name "${fmName}" must match directory "${name}"`);
    if (fmName.length > 64 || !NAME_RE.test(fmName)) fail(skillFile, `invalid name "${fmName}"`);
  }
  if (!description) fail(skillFile, "frontmatter missing `description`");
  else if (description.length > 1024) fail(skillFile, `description is ${description.length} chars (max 1024)`);

  const bodyLines = text.slice(fm.bodyStart).split(/\r?\n/).length;
  if (bodyLines > 500) fail(skillFile, `SKILL.md body is ${bodyLines} lines (max 500)`);

  for (const file of walk(dir)) {
    const content = readFileSync(file, "utf8");
    if (KEY_RE.test(content)) fail(file, "contains what looks like a real GameFlow API key");
    if (!file.endsWith(".md")) continue;
    // Relative links: [text](path) excluding URLs, anchors and mailto.
    for (const [, target] of content.matchAll(/\]\(([^)\s]+)\)/g)) {
      if (/^(https?:|mailto:|#)/.test(target)) continue;
      const path = target.split("#")[0];
      if (path && !existsSync(resolve(dirname(file), path))) fail(file, `broken link: ${target}`);
    }
  }
}

if (errors.length) {
  console.error(`✖ ${errors.length} problem(s):\n` + errors.map((e) => `  - ${e}`).join("\n"));
  process.exit(1);
}
console.log(`✔ ${skillNames.length} skills valid: ${skillNames.join(", ")}`);

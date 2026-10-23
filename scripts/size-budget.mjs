import { readdirSync, statSync } from "node:fs";
import { join } from "node:path";

/** Total-size budget for the built extension (bytes). Ratchet down, never up. */
const DEFAULT_BUDGET = 200 * 1024;
const budget = Number(process.env.NOCHE_SIZE_BUDGET ?? DEFAULT_BUDGET);
const root = new URL("../.output", import.meta.url).pathname;

function walk(dir) {
  let total = 0;
  const rows = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      const sub = walk(path);
      total += sub.total;
      rows.push(...sub.rows);
    } else {
      const size = statSync(path).size;
      total += size;
      rows.push({ path: path.replace(root + "/", ""), size });
    }
  }
  return { total, rows };
}

const { total, rows } = walk(root);
for (const row of rows.sort((a, b) => b.size - a.size)) {
  console.log(String(row.size).padStart(8), row.path);
}
const kb = (total / 1024).toFixed(1);
const budgetKb = (budget / 1024).toFixed(1);
console.log(`\ntotal: ${kb} KB / budget: ${budgetKb} KB`);
if (total > budget) {
  console.error(`SIZE BUDGET EXCEEDED by ${(total - budget) / 1024 | 0} KB`);
  process.exit(1);
}
console.log("size budget OK");

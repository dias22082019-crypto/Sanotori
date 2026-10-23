// Проверяет, что ru.json и kk.json содержат одинаковый набор ключей и нет пустых строк.
import { readFileSync } from "node:fs";

const load = (lang) => JSON.parse(readFileSync(new URL(`../src/i18n/${lang}.json`, import.meta.url), "utf8"));
const flatten = (obj, prefix = "") =>
  Object.entries(obj).flatMap(([k, v]) =>
    typeof v === "object" && v !== null ? flatten(v, `${prefix}${k}.`) : [[`${prefix}${k}`, v]],
  );

const ru = new Map(flatten(load("ru")));
const kk = new Map(flatten(load("kk")));
const problems = [];
for (const key of ru.keys()) if (!kk.has(key)) problems.push(`kk is missing ${key}`);
for (const key of kk.keys()) if (!ru.has(key)) problems.push(`ru is missing ${key}`);
for (const [lang, map] of [["ru", ru], ["kk", kk]])
  for (const [key, value] of map) if (typeof value !== "string" || value.trim() === "") problems.push(`${lang}.${key} is empty`);

if (problems.length) {
  console.error(problems.join("\n"));
  process.exit(1);
}
console.log(`i18n ok: ${ru.size} keys in ru and kk`);

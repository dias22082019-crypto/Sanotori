// Проверяет, что ru.json и kk.json содержат одинаковый набор ключей и нет пустых строк.
// Формы множественного числа (_one, _few, _many, _other) в языках различаются,
// поэтому сравниваются базовые ключи, а у каждого плюрального ключа должна быть форма _other.
import { readFileSync } from "node:fs";

const load = (lang) => JSON.parse(readFileSync(new URL(`../src/i18n/${lang}.json`, import.meta.url), "utf8"));
const flatten = (obj, prefix = "") =>
  Object.entries(obj).flatMap(([k, v]) =>
    typeof v === "object" && v !== null ? flatten(v, `${prefix}${k}.`) : [[`${prefix}${k}`, v]],
  );

const PLURAL = /_(zero|one|two|few|many|other)$/;
const ru = new Map(flatten(load("ru")));
const kk = new Map(flatten(load("kk")));
const base = (map) => new Set([...map.keys()].map((k) => k.replace(PLURAL, "")));
const problems = [];
const ruBase = base(ru);
const kkBase = base(kk);
for (const key of ruBase) if (!kkBase.has(key)) problems.push(`kk is missing ${key}`);
for (const key of kkBase) if (!ruBase.has(key)) problems.push(`ru is missing ${key}`);
for (const [lang, map] of [["ru", ru], ["kk", kk]])
  for (const key of map.keys())
    if (PLURAL.test(key) && !map.has(key.replace(PLURAL, "_other"))) problems.push(`${lang}.${key.replace(PLURAL, "")} has no _other form`);
for (const [lang, map] of [["ru", ru], ["kk", kk]])
  for (const [key, value] of map) if (typeof value !== "string" || value.trim() === "") problems.push(`${lang}.${key} is empty`);

if (problems.length) {
  console.error(problems.join("\n"));
  process.exit(1);
}
console.log(`i18n ok: ${ru.size} keys in ru and kk`);

#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const retiredExactKeys = new Set(['VIDEO_POLICY_TIMEZONE']);
const retiredPrefixes = ['DBZY_', 'SUIBIAN_'];

export function removeRetiredVideoEnvironment(input) {
  let removed = 0;
  const text = String(input || '');
  const output = text
    .split(/(?<=\n)/)
    .filter((line) => {
      const normalized = line
        .replace(/^[\t ]*/, '')
        .replace(/^export[\t ]+/, '');
      const key = /^([A-Za-z_][A-Za-z0-9_]*)[\t ]*=/.exec(normalized)?.[1] || '';
      const retired = retiredExactKeys.has(key)
        || retiredPrefixes.some((prefix) => key.startsWith(prefix));
      if (retired) removed += 1;
      return !retired;
    })
    .join('');
  return { output, removed };
}

function cleanFile(file) {
  const target = path.resolve(file);
  const original = fs.readFileSync(target, 'utf8');
  const result = removeRetiredVideoEnvironment(original);
  if (result.removed > 0) fs.writeFileSync(target, result.output, 'utf8');
  process.stdout.write(`retired_video_environment_entries_removed=${result.removed}\n`);
}

const isMain = process.argv[1]
  ? fileURLToPath(import.meta.url) === path.resolve(process.argv[1])
  : false;

if (isMain) {
  const file = process.argv[2];
  if (!file) throw new Error('environment file path is required');
  cleanFile(file);
}

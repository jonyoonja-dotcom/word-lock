import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = await readFile(path.join(root, 'LockWord', 'Resources', 'built_in_words.csv'), 'utf8');

function parseCsv(text) {
  const rows = [];
  let row = [], field = '', quoted = false;
  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    if (quoted) {
      if (char === '"' && text[i + 1] === '"') { field += '"'; i += 1; }
      else if (char === '"') quoted = false;
      else field += char;
    } else if (char === '"' && field.length === 0) quoted = true;
    else if (char === ',') { row.push(field); field = ''; }
    else if (char === '\n') { row.push(field.replace(/\r$/, '')); rows.push(row); row = []; field = ''; }
    else field += char;
  }
  if (field.length || row.length) { row.push(field.replace(/\r$/, '')); rows.push(row); }
  assert.equal(quoted, false, 'CSV has an unclosed quoted field');
  return rows;
}

const rows = parseCsv(source);
assert.deepEqual(rows[0].slice(0, 5), ['english', 'meaning', 'part', 'example', 'deck']);
const data = rows.slice(1).filter(row => row.some(value => value.trim().length));
const expected = new Map([
  ['초등', 800], ['중등 기본', 800], ['중등 고난도', 1800],
  ['고등 기본', 1000], ['고등 고난도', 500], ['고등 최상위', 300], ['회화', 1000],
]);
assert.equal(data.length, 6200, 'Expected 6,200 vocabulary rows');
const counts = new Map([...expected.keys()].map(deck => [deck, 0]));
const seen = new Set();
for (const [index, row] of data.entries()) {
  assert.equal(row.length, 8, `CSV row ${index + 2} should have 8 columns`);
  const [english, meaning, , , deck] = row;
  assert.ok(english.trim(), `CSV row ${index + 2} has no English word`);
  assert.ok(meaning.trim(), `CSV row ${index + 2} has no meaning`);
  assert.ok(counts.has(deck), `CSV row ${index + 2} has an unexpected deck: ${deck}`);
  const key = `${deck.toLocaleLowerCase()}\0${english.trim().toLocaleLowerCase()}`;
  assert.ok(!seen.has(key), `Duplicate spelling within ${deck}: ${english}`);
  seen.add(key);
  counts.set(deck, counts.get(deck) + 1);
}
assert.deepEqual(Object.fromEntries(counts), Object.fromEntries(expected));

const project = await readFile(path.join(root, 'LockWord.xcodeproj', 'project.pbxproj'), 'utf8');
assert.ok(project.includes('WordLockApp.swift in Sources'));
assert.ok(project.includes('built_in_words.csv in Resources'));
assert.ok(project.includes('kr.co.lockword.ios'));
assert.ok(await readFile(path.join(root, 'LockWord', 'WordLockApp.swift'), 'utf8'));
console.log(`WordLock iOS source check passed: ${data.length} words; ${counts.size} decks; all entries complete and unique per deck.`);


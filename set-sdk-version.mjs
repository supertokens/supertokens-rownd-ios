import { readFile, writeFile } from 'node:fs/promises';

const [version] = process.argv.slice(2);
if (!version) {
  throw new Error('A version is required');
}

const path = 'Sources/Rownd/framework/Version.swift';
const source = await readFile(path, 'utf8');
const updated = source.replace(/SDK_VERSION="[^"]+"/, `SDK_VERSION="${version}"`);

if (updated === source && !source.includes(`SDK_VERSION="${version}"`)) {
  throw new Error(`Could not update SDK_VERSION in ${path}`);
}

await writeFile(path, updated);

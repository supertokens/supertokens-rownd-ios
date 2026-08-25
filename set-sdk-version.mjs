import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

export function replaceSdkVersion(source, version) {
  return source.replace(/SDK_VERSION\s*=\s*"[^"]+"/, `SDK_VERSION = "${version}"`);
}

async function main() {
  const [version] = process.argv.slice(2);
  if (!version) {
    throw new Error('A version is required');
  }

  const path = 'Sources/Rownd/framework/Version.swift';
  const source = await readFile(path, 'utf8');
  const updated = replaceSdkVersion(source, version);

  if (updated === source && !source.includes(`SDK_VERSION = "${version}"`)) {
    throw new Error(`Could not update SDK_VERSION in ${path}`);
  }

  await writeFile(path, updated);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main();
}

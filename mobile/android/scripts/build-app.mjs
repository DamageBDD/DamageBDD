import { access, cp, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const appRoot = process.cwd();
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const mobileRoot = path.resolve(scriptDir, '..');
const sourceDir = path.join(appRoot, 'src');
const sharedDir = path.join(mobileRoot, 'shared', 'web');
const outputDir = path.join(appRoot, 'www');

async function requirePath(target, description) {
  try {
    await access(target);
  } catch {
    throw new Error(`${description} is missing: ${target}`);
  }
}

await requirePath(path.join(sourceDir, 'index.html'), 'App entry point');
await requirePath(sharedDir, 'Shared web source');

await rm(outputDir, { recursive: true, force: true });
await mkdir(outputDir, { recursive: true });
await cp(sourceDir, outputDir, { recursive: true });
await cp(sharedDir, path.join(outputDir, 'shared'), { recursive: true });

console.log(`Built ${path.basename(appRoot)} web assets -> ${outputDir}`);

#!/usr/bin/env node
// Mechanical exports of Opus's editable artwork. Keep the source SVG as the
// design authority; changing output sizes must not redesign the website icon.
import { readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const rendererPath = process.argv[2];
if (!rendererPath) {
  throw new Error('Pass the installed @resvg/resvg-js package path; run exports on the Mini.');
}
const require = createRequire(import.meta.url);
const rendererVersion = require(resolve(rendererPath, 'package.json')).version;
if (rendererVersion !== '2.6.2') {
  throw new Error(`Expected @resvg/resvg-js 2.6.2, found ${rendererVersion}; audit before changing the renderer.`);
}
const { Resvg } = require(resolve(rendererPath));
const svg = await readFile(resolve(root, 'design/agentflow-surfer.svg'), 'utf8');
// App assets must remain inert, self-contained and text-free. resvg never
// executes scripts, but reject dependencies that could make exports drift.
if (!/viewBox="0 0 1024 1024"/.test(svg)
    || /<(?:script|foreignObject|image|text)\b|\b(?:href|on\w+)\s*=|<!DOCTYPE|<!ENTITY|url\(\s*[^#]/i.test(svg)) {
  throw new Error('Expected a self-contained 1024-square vector icon without external resources.');
}
for (const size of [16, 32, 64, 128, 256, 512, 1024]) {
  const png = new Resvg(svg, { fitTo: { mode: 'width', value: size } }).render().asPng();
  await writeFile(resolve(root, `VoiceInk/Assets.xcassets/AppIcon.appiconset/${size}-mac.png`), png);
  if (size === 128) await writeFile(resolve(root, 'docs/assets/agentflow-icon.png'), png);
  if (size === 512) await writeFile(resolve(root, 'docs/assets/agentflow-icon-512.png'), png);
  console.log(`Exported ${size} x ${size}`);
}

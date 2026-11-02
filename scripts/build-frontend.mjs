#!/usr/bin/env node
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Generates the third-party front-end libraries served by BMO — scripts,
// stylesheets and their asset files — from the versions pinned in package.json
// / package-lock.json.
//
//   npm run build              write into ./js (the working tree)
//   npm run build -- --out=D   write into D instead, laid out the same way
//
// The generated files are NOT committed: the Docker `assets` stage runs this
// with --out and the result is copied over /app/js, so the image always matches
// package-lock.json. Run it in the working tree if you want to serve BMO from a
// checkout directly.
//
// Only third-party libraries live here. First-party BMO JavaScript stays in the
// repository as-is. bpopup is not published to npm and remains vendored under
// js/jquery/plugins/bPopup/.

import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const root = join(scriptDir, '..');
const nm = join(root, 'node_modules');

const outArg = process.argv.find((a) => a.startsWith('--out='));
const outDir = outArg ? outArg.slice('--out='.length) : join(root, 'js');

// Prism: concatenate the core runtime with exactly the language grammars BMO
// uses. No plugins — in particular NOT the autolinker plugin, whose unsanitised
// href handling was the DOM-XSS in bug 2055861.
const PRISM_LANGS = [
  'core', 'markup', 'css', 'clike', 'javascript', 'c', 'cpp',
  'diff', 'http', 'json', 'markdown', 'perl', 'python', 'rust', 'yaml',
];

function prismBundle() {
  const version = JSON.parse(
    readFileSync(join(nm, 'prismjs/package.json'), 'utf8'),
  ).version;
  const header =
    `/* PrismJS ${version}\n` +
    `https://prismjs.com/download.html#themes=prism&languages=` +
    `${PRISM_LANGS.filter((l) => l !== 'core').join('+')} */\n`;
  const body = PRISM_LANGS
    .map((l) => readFileSync(join(nm, `prismjs/components/prism-${l}.min.js`), 'utf8').trimEnd())
    .join('\n');
  return Buffer.from(header + body + '\n');
}

// dest (relative to the output directory, i.e. to js/) -> source under
// node_modules, or a function returning the bytes to write.
//
// A library's stylesheet is generated from the same package as its script, so
// the two cannot drift apart. The .map files keep their upstream names because
// that is what the sourceMappingURL comments inside the minified files point
// at; they carry their sources inline, so they are self-contained.
const TARGETS = {
  'lib/prism.js': prismBundle,
  'lib/mermaid.min.js': 'mermaid/dist/mermaid.min.js',
  'lib/md5.min.js': 'blueimp-md5/js/md5.min.js',
  'jquery/jquery-min.js': 'jquery/dist/jquery.min.js',

  'jquery/ui/jquery-ui-min.js': 'jquery-ui-dist/jquery-ui.min.js',
  'jquery/ui/jquery-ui-min.css': 'jquery-ui-dist/jquery-ui.min.css',
  'jquery/ui/jquery-ui-structure-min.css': 'jquery-ui-dist/jquery-ui.structure.min.css',
  'jquery/ui/jquery-ui-theme-min.css': 'jquery-ui-dist/jquery-ui.theme.min.css',

  'jquery/plugins/contextMenu/contextMenu-min.js':
    'jquery-contextmenu/dist/jquery.contextMenu.min.js',
  'jquery/plugins/contextMenu/jquery.contextMenu.min.js.map':
    'jquery-contextmenu/dist/jquery.contextMenu.min.js.map',
  'jquery/plugins/contextMenu/contextMenu.css':
    'jquery-contextmenu/dist/jquery.contextMenu.min.css',
  'jquery/plugins/contextMenu/jquery.contextMenu.min.css.map':
    'jquery-contextmenu/dist/jquery.contextMenu.min.css.map',

  'jquery/plugins/datetimepicker/datetimepicker-min.js':
    'jquery-datetimepicker/build/jquery.datetimepicker.full.min.js',
  'jquery/plugins/datetimepicker/datetimepicker.css':
    'jquery-datetimepicker/jquery.datetimepicker.css',

  'jquery/plugins/devbridgeAutocomplete/devbridgeAutocomplete-min.js':
    'devbridge-autocomplete/dist/jquery.autocomplete.min.js',
  'jquery/plugins/devbridgeAutocomplete/license.txt':
    'devbridge-autocomplete/LICENSE',
};

// Whole directories copied verbatim: destination (relative to js/) -> source
// under node_modules. These hold the images and icon fonts that the generated
// stylesheets reference by relative URL, so they have to sit next to them.
const TARGET_DIRS = {
  'jquery/ui/images': 'jquery-ui-dist/images',
  'jquery/plugins/contextMenu/font': 'jquery-contextmenu/dist/font',
};

function write(dest, bytes) {
  const path = join(outDir, dest);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, bytes);
  console.log(`wrote  js/${dest} (${bytes.length} bytes)`);
}

for (const [dest, source] of Object.entries(TARGETS)) {
  write(dest, typeof source === 'function' ? source() : readFileSync(join(nm, source)));
}

// Recurse, so that a library keeping its assets in subdirectories is copied
// whole rather than silently arriving half-empty with broken URLs in its
// stylesheet. Symlinks are resolved to whatever they point at.
function copyDir(destDir, srcDir) {
  for (const entry of readdirSync(srcDir, { withFileTypes: true })) {
    const from = join(srcDir, entry.name);
    const node = entry.isSymbolicLink() ? statSync(from) : entry;
    if (node.isDirectory()) {
      copyDir(`${destDir}/${entry.name}`, from);
    } else if (node.isFile()) {
      write(`${destDir}/${entry.name}`, readFileSync(from));
    } else {
      throw new Error(`${from} is neither a file nor a directory`);
    }
  }
}

for (const [destDir, srcRel] of Object.entries(TARGET_DIRS)) {
  copyDir(destDir, join(nm, srcRel));
}

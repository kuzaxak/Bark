// Check the globals supplied by Bark's Chromium renderer to the bundled uBO scriptlets.
//   node scripts/check-scriptlet-globals.mjs
import { readFileSync, readdirSync } from 'fs';
import assert from 'assert';

const root = new URL('..', import.meta.url).pathname;
const dir = root + 'Packages/NookBlocker/ThirdParty/ubo-scriptlets/src/js/resources/';
const patch = readFileSync(root + 'Runtime/Chromium/patches/chrome/renderer/chrome_render_frame_observer.cc.patch', 'utf8');
const wrapper = patch.split('\n').filter(line => line.startsWith('+') && !line.startsWith('+++')).join('\n');

const expected = new Set();
for (const file of readdirSync(dir).filter(f => f.endsWith('.js'))) {
  for (const m of readFileSync(dir + file, 'utf8').matchAll(/\/\*\s*globals?\s+([^*]+)\*\//g)) {
    m[1].split(/[\s,]+/).filter(Boolean).forEach(name => expected.add(name.split(':')[0]));
  }
}
assert(expected.has('scriptletGlobals'), 'expected the library to declare scriptletGlobals');
for (const name of expected) {
  assert(wrapper.includes(`const ${name}=`), `Chromium renderer must define ${name} around the scriptlets`);
}
console.log(`scriptlet globals ok: ${[...expected].join(', ')}`);

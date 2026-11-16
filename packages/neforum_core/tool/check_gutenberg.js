// Usage, from packages/neforum_core, in a scratch folder with the parser:
//   npm init -y; npm i @wordpress/block-serialization-default-parser   (in <scratch>)
//   NODE_PATH=<scratch>/node_modules node tool/check_gutenberg.js test/fixtures/article/wordpress_gutenberg.golden
// test/article/article_serializers_test.dart checks the same in Dart, so CI needs no Node.
// Parses NEFORUM's Gutenberg output with WordPress's official block parser
// and asserts no freeform (Classic) block and the expected block names.
// Usage: node check_gutenberg.js <golden file> (run with NODE_PATH pointing at
// the folder that has @wordpress/block-serialization-default-parser).
const fs = require('fs');
const { parse } = require('@wordpress/block-serialization-default-parser');

const raw = fs.readFileSync(process.argv[2], 'utf8').replace(/\r\n/g, '\n');
const content = raw.split('\n---- report')[0];
const blocks = parse(content);
const names = [];
let freeform = 0;
function walk(list, depth) {
  for (const b of list) {
    if (b.blockName === null) {
      if (b.innerHTML.trim() !== '') freeform++;
      continue;
    }
    names.push('  '.repeat(depth) + b.blockName + (Object.keys(b.attrs).length ? ' ' + JSON.stringify(b.attrs) : ''));
    walk(b.innerBlocks, depth + 1);
  }
}
walk(blocks, 0);
console.log(names.join('\n'));
const expected = [
  'core/heading', 'core/paragraph', 'core/image', 'core/gallery', 'core/heading', 'core/video', 'core/audio',
  'core/embed', 'core/quote', 'core/list', 'core/list', 'core/code', 'core/separator', 'core/paragraph',
];
const top = blocks.filter((b) => b.blockName !== null).map((b) => b.blockName);
if (freeform !== 0) { console.error('FAIL: freeform content outside blocks: ' + freeform); process.exit(1); }
if (JSON.stringify(top) !== JSON.stringify(expected)) { console.error('FAIL: top-level blocks ' + JSON.stringify(top)); process.exit(1); }
const gallery = blocks.find((b) => b.blockName === 'core/gallery');
if (gallery.innerBlocks.length !== 3 || gallery.innerBlocks.some((b) => b.blockName !== 'core/image')) { console.error('FAIL: gallery'); process.exit(1); }
console.log('OK: ' + top.length + ' top-level blocks, 0 freeform');

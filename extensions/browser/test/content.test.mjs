// Checks the content scripts' page-independent parts: the text helpers, the
// recipe table and the manifests. (Filling real editors is checked in a
// browser with the pages in test/pages.)
//   node --test extensions/browser/test/content.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

/** Loads fill.js and recipes.js as the browser would, without a page. */
function loadContent() {
  const sandbox = { console, setTimeout, clearTimeout };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  for (const file of ['fill.js', 'recipes.js']) {
    vm.runInContext(readFileSync(new URL(`../src/content/${file}`, import.meta.url), 'utf8'), sandbox, { filename: file });
  }
  return sandbox.NEFORUM_EXT;
}

const manifest = (browser) => JSON.parse(readFileSync(new URL(`../manifest.${browser}.json`, import.meta.url), 'utf8'));

/** The art and portfolio sites NEFORUM hands off to, with their upload hosts. */
const ART_SITES = {
  behance: 'www.behance.net',
  artstation: 'www.artstation.com',
  cara: 'cara.app',
  pixiv: 'www.pixiv.net',
  itaku: 'itaku.ee',
  newgrounds: 'www.newgrounds.com',
  furaffinity: 'www.furaffinity.net',
  weasyl: 'www.weasyl.com',
  kofi: 'ko-fi.com',
  artfol: 'artfol.app',
  fivehundredpx: '500px.com',
  dribbble: 'dribbble.com',
  flickr: 'www.flickr.com',
};

test('a field that shows how the text begins gets only the rest (no part twice)', () => {
  const { restAfter } = loadContent().fill;
  // A link prefilled the first part of a thread; the job's text is all of it.
  assert.equal(restAfter('Short one\n\nPart two\n\nPart three', 'Short one'), '\n\nPart two\n\nPart three');
  // A first part longer than 40 characters: the rest still goes in.
  const long = 'This first part is clearly longer than forty characters.';
  assert.equal(restAfter(`${long}\n\nAnd the second.`, long), '\n\nAnd the second.');
  // What the field shows has blanks collapsed (innerText of paragraphs).
  assert.equal(restAfter('One  two\nthree\n\nfour', 'One two three'), '\n\nfour');
  assert.equal(restAfter('  Leading blanks', 'Leading'), ' blanks');
  // Something else in the field: not the start of this text.
  assert.equal(restAfter('Hello world', 'Goodbye'), null);
  assert.equal(restAfter('Hi', 'Hi there'), null, 'the field holds more than the text');
  assert.equal(restAfter('Same', 'Same'), '', 'all of it is there already');
});

test('thread parts: X, Bluesky, Threads and Mastodon add post boxes; the others take the text as one post', () => {
  const { recipes } = loadContent();
  for (const id of ['x', 'bluesky', 'threads', 'mastodon']) assert.equal(typeof recipes[id].addPart, 'function', id);
  for (const id of ['linkedin', 'facebook', 'tumblr', 'instagram']) assert.equal(recipes[id].addPart, undefined, id);
});

test('YouTube: Posts fill polls, quizzes and image polls; uploads fill the title and leave the audience question to the user', () => {
  const { recipes } = loadContent();
  const posts = recipes.youtube_posts;
  assert.equal(typeof posts.fields, 'function');
  assert.equal(typeof posts.attach, 'function', 'image poll answers each get their image');
  assert.equal(posts.manualPublish, undefined, 'a post can be posted automatically');
  const upload = recipes.youtube;
  assert.ok(upload.mediaFirst);
  assert.ok(upload.replaceTitle, 'Studio puts the file name in the title first');
  assert.match(upload.manualPublish, /made for kids/);
  assert.equal(upload.titleFor({ title: 'Raw', snippets: [{ label: 'Title', text: 'Clean' }] }), 'Clean');
  assert.equal(upload.titleFor({ title: 'Raw', snippets: [] }), 'Raw');
});

test('every art and portfolio site has a recipe that fills its form and knows how it is published', () => {
  const { recipes } = loadContent();
  for (const [id] of Object.entries(ART_SITES)) {
    const r = recipes[id];
    assert.ok(r, `${id} has a recipe`);
    assert.equal(typeof r.fields, 'function', `${id} fills its own fields`);
    assert.ok(r.manualPublish || r.postWords?.length || r.postPattern, `${id}: a Post button to press, or why the user publishes`);
  }
  // Sites whose last step is a choice only the user can make.
  for (const id of ['behance', 'newgrounds', 'furaffinity']) assert.ok(recipes[id].manualPublish, id);
  assert.ok(recipes.furaffinity.stepPages, 'filled in page by page');
  assert.deepEqual([...recipes.itaku.afterPostWords].slice(0, 2), ['yes', 'confirm'], 'Itaku asks to confirm the ratings');
  assert.ok(recipes.flickr.postPattern.test('upload 3 photos'));
  assert.ok(!recipes.flickr.postPattern.test('upload settings'));
});

test('sites where posting needs the user stay manual even for automatic jobs', () => {
  const { recipes } = loadContent();
  for (const id of ['reddit', 'whatsapp', 'youtube']) assert.ok(recipes[id].manualPublish, id);
});

test('tags: the job\'s list, else the Tags snippet', () => {
  const { tagsOf } = loadContent().recipeHelpers;
  assert.deepEqual([...tagsOf({ tags: ['cats', 'art'] })], ['cats', 'art']);
  assert.deepEqual([...tagsOf({ tags: [], snippets: [{ label: 'Tags', text: 'cats, digital art, #sketch' }] })], ['cats', 'digital art', 'sketch']);
  assert.deepEqual([...tagsOf({ snippets: [] })], []);
});

test('manifests: version 1.1.0 in both, the same pages, art sites and YouTube Studio included', () => {
  const chrome = manifest('chrome');
  const firefox = manifest('firefox');
  assert.equal(chrome.version, '1.1.0');
  assert.equal(firefox.version, chrome.version);
  assert.deepEqual(firefox.content_scripts, chrome.content_scripts);
  assert.ok(chrome.description.length <= 132, 'the Chrome Web Store limit');
  const matches = chrome.content_scripts[0].matches;
  for (const [id, host] of Object.entries(ART_SITES)) assert.ok(matches.includes(`https://${host}/*`), `${id}: ${host}`);
  assert.ok(matches.includes('https://studio.youtube.com/*'));
  assert.deepEqual(chrome.host_permissions, ['http://127.0.0.1/*'], 'still only the app on this computer');
});

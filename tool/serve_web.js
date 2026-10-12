// Tiny static server for the NEFORUM web preview (no dependencies).
//   node tool/serve_web.js [port] [folder]
// [folder] (relative to the repository) serves something else, e.g.
// extensions/browser for the extension's test pages.
const http = require('http');
const fs = require('fs');
const path = require('path');

const spa = !process.argv[3];
const root = spa ? path.join(__dirname, '..', 'apps', 'neforum_app', 'build', 'web') : path.resolve(__dirname, '..', process.argv[3]);
const port = Number(process.argv[2] || process.env.PORT || 8765);
const types = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json',
  '.wasm': 'application/wasm', '.png': 'image/png', '.ico': 'image/x-icon', '.svg': 'image/svg+xml',
  '.ttf': 'font/ttf', '.otf': 'font/otf', '.woff2': 'font/woff2', '.md': 'text/markdown; charset=utf-8', '.css': 'text/css',
};

http.createServer((req, res) => {
  const url = decodeURIComponent((req.url || '/').split('?')[0]);
  let file = path.normalize(path.join(root, url));
  if (!file.startsWith(root)) { res.writeHead(403); return res.end(); }
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    if (!spa) { res.writeHead(404); return res.end(); }
    file = path.join(root, 'index.html');
  }
  res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
  fs.createReadStream(file).pipe(res);
}).listen(port, '127.0.0.1', () => console.log(`NEFORUM web preview on http://127.0.0.1:${port}`));

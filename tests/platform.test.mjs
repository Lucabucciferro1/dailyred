// Fast checks for the Windows launcher output and portable local server.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { gunzipSync } from 'node:zlib';
import { ROOT, GAME_DIR, startServer } from './lib.mjs';

let server, baseUrl;
before(async () => {
  server = await startServer();
  // Node 18 may resolve localhost to IPv6 without trying the IPv4 listener.
  baseUrl = server.url.replace('localhost', '127.0.0.1');
});
after(() => server?.close());

test('serves the site with no-cache headers', async () => {
  const response = await fetch(baseUrl);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /^text\/html/);
  assert.equal(response.headers.get('cache-control'), 'no-cache');
  assert.equal(await response.text(), await readFile(join(ROOT, 'web/index.html'), 'utf8'));
});

test('rejects encoded traversal, including paths sharing the web prefix', async () => {
  for (const path of ['/..%2FREADME.md', '/..%2Fweb-sibling%2Fprivate.txt']) {
    assert.equal((await fetch(baseUrl + path)).status, 403, path);
  }
  if (process.platform === 'win32') {
    for (const path of ['/..%5CREADME.md', '/..%5Cweb-sibling%5Cprivate.txt']) {
      assert.equal((await fetch(baseUrl + path)).status, 403, path);
    }
  }
  assert.equal((await fetch(`${baseUrl}/%FF`)).status, 404);
  assert.equal((await fetch(baseUrl)).status, 200, 'malformed requests do not stop the server');
});

test('serves the locally built ROM as gzip bytes that match the original', async () => {
  const response = await fetch(`${baseUrl}/game/dailyred.gba.gz`);
  assert.equal(response.status, 200);
  // The app decompresses this file itself, so no HTTP Content-Encoding header.
  assert.equal(response.headers.get('content-encoding'), null);
  const rom = gunzipSync(Buffer.from(await response.arrayBuffer()));
  assert.equal(rom.length, 16 * 1024 * 1024);
  assert.deepEqual(rom, await readFile(join(GAME_DIR, 'pokefirered_modern.gba')));
  assert.notEqual(rom.indexOf('DAILYRED-CONF-V2'), -1, 'the game patch is present');
});

test('serves the emulator and font with browser-compatible MIME types', async () => {
  for (const [path, type] of [
    ['vendor/mgba_libretro.wasm', 'application/wasm'],
    ['vendor/pixelify-sans.woff2', 'font/woff2'],
    ['game/red.png', 'image/png'],
  ]) {
    const response = await fetch(`${baseUrl}/${path}`);
    assert.equal(response.status, 200, path);
    assert.equal(response.headers.get('content-type'), type);
    assert.ok((await response.arrayBuffer()).byteLength > 0);
  }
});

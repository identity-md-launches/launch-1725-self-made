import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configure, parseArgs, readWorkshop } from '../../scripts/configure-gallery.mjs';

const HOOK = '0x00000000000000000000000000000000000020cc';
const WORKSHOP = '0x1111111111111111111111111111111111111111';
const word = (address) => `0x${address.slice(2).padStart(64, '0')}`;

// A tiny JSON-RPC stub: chain id, code presence per address, and the hook's workshop() answer.
function rpc(overrides = {}) {
  const state = { chainId: '0x1237', code: { [HOOK]: '0x6001', [WORKSHOP]: '0x6002' }, workshop: word(WORKSHOP), ...overrides };
  const server = createServer((request, response) => {
    let body = '';
    request.on('data', (chunk) => { body += chunk; });
    request.on('end', () => {
      const { id, method, params } = JSON.parse(body);
      let result;
      if (method === 'eth_chainId') result = state.chainId;
      else if (method === 'eth_getCode') result = state.code[params[0].toLowerCase()] ?? '0x';
      else if (method === 'eth_call' && params[0].to === HOOK && params[0].data === '0x720c4798') result = state.workshop;
      else { response.end(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32601, message: `unexpected ${method}` } })); return; }
      response.end(JSON.stringify({ jsonrpc: '2.0', id, result }));
    });
  });
  return new Promise((done) => server.listen(0, '127.0.0.1', () => done({ url: `http://127.0.0.1:${server.address().port}`, close: () => server.close() })));
}

function freshConfig() {
  const path = join(mkdtempSync(join(tmpdir(), 'gallery-')), 'config.json');
  writeFileSync(path, `${JSON.stringify({ chainId: 4663, rpcUrl: 'https://rpc.example', explorerUrl: 'https://x', workshop: null, deploymentBlock: null, confirmations: 2 }, null, 2)}\n`);
  return path;
}

test('argument validation refuses a missing, zero or malformed hook and a bad block', () => {
  assert.throws(() => parseArgs(['--deployment-block', '5']), /--hook/);
  assert.throws(() => parseArgs(['--hook', `0x${'0'.repeat(40)}`, '--deployment-block', '5']), /--hook/);
  assert.throws(() => parseArgs(['--hook', '0x1234', '--deployment-block', '5']), /--hook/);
  assert.throws(() => parseArgs(['--hook', HOOK, '--deployment-block', '0']), /--deployment-block/);
  assert.throws(() => parseArgs(['--hook', HOOK, '--deployment-block', 'soon']), /--deployment-block/);
  assert.throws(() => parseArgs(['--hook', HOOK, '--deployment-block', '5', '--rpc-url', 'ftp://x']), /--rpc-url/);
  assert.throws(() => parseArgs(['--hook', HOOK, '--deployment-block', '5', '--extra']), /Unexpected/);
  assert.deepEqual(parseArgs(['--hook', HOOK.toUpperCase().replace('0X', '0x'), '--deployment-block', '42']), { hook: HOOK, deploymentBlock: 42, rpcUrl: undefined });
});

test('the Workshop address comes from the hook, not from the command line', async () => {
  const server = await rpc();
  try {
    const path = freshConfig();
    const result = await configure(['--hook', HOOK, '--deployment-block', '77', '--rpc-url', server.url], path);
    assert.deepEqual(result, { hook: HOOK, workshop: WORKSHOP, deploymentBlock: 77 });
    const written = JSON.parse(readFileSync(path, 'utf8'));
    assert.equal(written.workshop, WORKSHOP);
    assert.equal(written.deploymentBlock, 77);
    assert.equal(written.rpcUrl, server.url);
    assert.equal(written.chainId, 4663);
    assert.equal(written.confirmations, 2);
  } finally { server.close(); }
});

test('config is left untouched when the hook has no code, reports no Workshop, or the chain is wrong', async () => {
  const cases = [
    [{ code: { [WORKSHOP]: '0x6002' } }, /No SelfHook code/],
    [{ code: { [HOOK]: '0x6001' } }, /No Workshop code/],
    [{ workshop: word(`0x${'0'.repeat(40)}`) }, /zero address/],
    [{ workshop: '0x' }, /other than an address/],
    [{ chainId: '0x1' }, /expected 4663/],
  ];
  for (const [overrides, expected] of cases) {
    const server = await rpc(overrides);
    try {
      const path = freshConfig();
      const before = readFileSync(path, 'utf8');
      await assert.rejects(configure(['--hook', HOOK, '--deployment-block', '77', '--rpc-url', server.url], path), expected);
      assert.equal(readFileSync(path, 'utf8'), before);
    } finally { server.close(); }
  }
});

test('readWorkshop returns the checksummed-insensitive lowercase address', async () => {
  const server = await rpc({ workshop: word(WORKSHOP.toUpperCase().replace('0X', '0x')) });
  try {
    assert.equal(await readWorkshop(server.url, HOOK, 4663), WORKSHOP);
  } finally { server.close(); }
});

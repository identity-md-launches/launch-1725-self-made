import test from 'node:test';
import assert from 'node:assert/strict';
import { ACTION, BUILT_TOPIC, SELECTORS, addressWord, decodeBuilt, safeURI, formatIMD, countdown, mergeLogs, readLogs, readStatus, makeRPC, validateConfig } from '../chain.mjs';
const word = x => BigInt(x).toString(16).padStart(64, '0');
function event(uri = 'ipfs://bafydelivery/artifacts/image.png', block = 50, index = 1) {
  const data = Buffer.from(uri).toString('hex');
  return { address: '0x' + '12'.repeat(20), topics: [BUILT_TOPIC, '0x' + 'ab'.repeat(32), '0x' + word(0)], data: '0x' + 'cd'.repeat(32) + word(64) + word(Buffer.byteLength(uri)) + data.padEnd(Math.ceil(data.length / 64) * 64, '0'), blockNumber: '0x' + block.toString(16), logIndex: '0x' + index.toString(16), transactionHash: '0x' + 'ef'.repeat(32), blockHash: '0x' + '56'.repeat(32) };
}
test('decodes actual Built ABI shape and UTF-8', () => {
  const result = decodeBuilt(event('https://example.org/creation/✓'));
  assert.equal(result.uri, 'https://example.org/creation/✓'); assert.equal(result.templateIndex, 0);
  assert.equal(result.resultHash, '0x' + 'cd'.repeat(32)); assert.equal(result.blockNumber, 50);
  assert.equal(decodeBuilt({ ...event(), removed: true }), null);
  assert.throws(() => decodeBuilt({ ...event(), data: '0x01' }));
  assert.throws(() => decodeBuilt(event('a'.repeat(2049))));
});
test('only safe links are exposed and IPFS resolves without HTML injection', () => {
  assert.equal(safeURI('javascript:alert(1)'), null); assert.equal(safeURI('data:text/html,abc'), null);
  assert.equal(safeURI('http://unsafe.example'), null); assert.equal(safeURI('https://user:password@example.org'), null);
  assert.equal(safeURI('ipfs://bafycid/image.png'), 'https://ipfs.io/ipfs/bafycid/image.png');
  assert.equal(safeURI('ar://abc'), 'https://arweave.net/abc');
  assert.equal(safeURI('ipfs://<script>'), null);
});
test('preserves precision for token amounts and countdown boundaries', () => {
  assert.equal(formatIMD(123456789012345678901234n), '123,456.789');
  assert.equal(formatIMD(500000000000000000n), '0.5');
  assert.equal(countdown(21600, 0), '06:00:00'); assert.equal(countdown(21600, 21600), 'Ready');
  assert.equal(countdown(21600, 21599.1), '00:00:01');
  assert.equal(ACTION, '0x' + Buffer.from('job.open@job-1').toString('hex').padEnd(64, '0'));
});
test('reorg overlap removes replaced logs and sorts newest first', () => {
  const a = decodeBuilt(event('https://example.org/a', 45));
  const b = decodeBuilt(event('https://example.org/b', 50));
  const c = decodeBuilt(event('https://example.org/c', 51, 2));
  const merged = mergeLogs([a, b], [c], 48);
  assert.deepEqual(merged.map(x => x.uri), [c.uri, a.uri]);
  assert.equal(mergeLogs([a], [a, a], 40).length, 1);
});
test('history pagination retries smaller ranges and filters removed logs', async () => {
  const calls = [];
  const rpc = async (_, [filter]) => {
    const from = Number(BigInt(filter.fromBlock)), to = Number(BigInt(filter.toBlock)); calls.push([from, to]);
    if (to - from > 2) throw new Error('range too large');
    return from <= 50 && to >= 50 ? [event(), { ...event(), removed: true }] : [];
  };
  const logs = await readLogs(rpc, event().address, 45, 55);
  assert.equal(logs.length, 1); assert.equal(logs[0].blockNumber, 50); assert.ok(calls.length > 4);
});
test('readStatus uses a consistent block, reads the live price, and includes bounty', async () => {
  const address = event().address, block = { number: '0x32', timestamp: '0x1000' };
  const rpc = async (method, [params, tag]) => {
    assert.equal(method, 'eth_call'); assert.equal(tag, block.number);
    const value = params.data.startsWith(SELECTORS.priceOf) ? 7n * 10n ** 18n : params.data.startsWith(SELECTORS.balanceOf) ? 8n * 10n ** 18n : 1n;
    return '0x' + word(value);
  };
  const status = await readStatus(rpc, { workshop: address }, block);
  assert.equal(status.price, 7n * 10n ** 18n); assert.equal(status.bounty, 14n * 10n ** 16n); assert.equal(status.canCommission, true);
});
test('RPC transport propagates errors and malformed responses', async () => {
  await assert.rejects(makeRPC('https://rpc.example', async () => ({ ok: false, status: 503 }))('eth_chainId'), /503/);
  await assert.rejects(makeRPC('https://rpc.example', async () => ({ ok: true, json: async () => ({ error: { message: 'wrong request' } }) }))('eth_chainId'), /wrong request/);
  await assert.rejects(makeRPC('https://rpc.example', async () => ({ ok: true, json: async () => ({}) }))('eth_chainId'), /Malformed/);
});
test('prelaunch config is explicit and invalid addresses are rejected', () => {
  const config = { chainId: 4663, rpcUrl: 'https://rpc.example', workshop: null, deploymentBlock: null };
  assert.equal(validateConfig(config), false);
  assert.throws(() => addressWord('0x1234'));
  assert.throws(() => validateConfig({ ...config, chainId: 1 }));
  assert.equal(validateConfig({ ...config, workshop: event().address, deploymentBlock: 42 }), true);
  assert.throws(() => validateConfig({ ...config, workshop: '0x' + '0'.repeat(40), deploymentBlock: 42 }));
});

export const IMD = '0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127';
export const INTAKE = '0xa43e6f75ee006411f79ac1c84120606c2330de82';
export const ACTION = '0x' + Array.from(new TextEncoder().encode('job.open@job-1'), x => x.toString(16).padStart(2, '0')).join('').padEnd(64, '0');
export const BUILT_TOPIC = '0x62f38612e62a40963fbab130ec6da6afd2bf1446546f11afda87c3109e7a7e99';
export const SELECTORS = Object.freeze({ balanceOf: '0x70a08231', nextTemplate: '0x6c2f70fd', lastCommissionAt: '0x7ba9bd0b', commissionsToday: '0x8f28d76c', canCommission: '0x26801500', nextCommissionAt: '0x0e6f3e26', workCount: '0x3343fa42', commission: '0xe1489191', priceOf: '0x51102885' });
export const TEMPLATES = ['Original meme', 'Vertical video', 'Workshop report', 'Security review'];
export const hex = n => '0x' + BigInt(n).toString(16);
export const addressWord = address => {
  if (!/^0x[0-9a-fA-F]{40}$/.test(address)) throw new Error('Invalid contract address');
  return address.slice(2).toLowerCase().padStart(64, '0');
};
export function validateConfig(config) {
  if (config.chainId !== 4663) throw new Error('This gallery requires Robinhood Chain (4663).');
  const rpc = new URL(config.rpcUrl);
  if (!['https:', 'http:'].includes(rpc.protocol)) throw new Error('Invalid RPC URL');
  if (!config.workshop || config.deploymentBlock === null) return false;
  addressWord(config.workshop);
  if (/^0x0{40}$/i.test(config.workshop) || !Number.isSafeInteger(config.deploymentBlock) || config.deploymentBlock < 0) throw new Error('Invalid deployment configuration');
  return true;
}
export function makeRPC(url, fetcher = fetch) {
  let id = 0;
  return async (method, params = []) => {
    const response = await fetcher(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }), signal: AbortSignal.timeout(20000) });
    if (!response.ok) throw new Error(`RPC HTTP ${response.status}`);
    const result = await response.json();
    if (result.error) throw new Error(result.error.message || 'RPC request failed');
    if (!Object.hasOwn(result, 'result')) throw new Error('Malformed RPC response');
    return result.result;
  };
}
export function decodeBuilt(log) {
  if (log.removed || log.topics?.[0]?.toLowerCase() !== BUILT_TOPIC) return null;
  if (!/^0x[0-9a-fA-F]*$/.test(log.data) || log.topics.length !== 3) throw new Error('Malformed Built event');
  const data = log.data.slice(2);
  const word = offset => {
    const value = data.slice(offset * 2, offset * 2 + 64);
    if (value.length !== 64) throw new Error('Truncated event');
    return BigInt('0x' + value);
  };
  const offset = Number(word(32));
  if (offset !== 64) throw new Error('Invalid URI offset');
  const length = Number(word(offset));
  if (length > 2048 || length < 0 || data.length < (offset + 32 + length) * 2) throw new Error('Invalid URI length');
  const uriHex = data.slice((offset + 32) * 2, (offset + 32 + length) * 2);
  const bytes = Uint8Array.from(uriHex.match(/.{2}/g) || [], x => parseInt(x, 16));
  const templateIndex = Number(BigInt(log.topics[2]));
  if (templateIndex < 0 || templateIndex > 3 || !/^0x[0-9a-fA-F]{64}$/.test(log.topics[1])) throw new Error('Invalid work identity');
  return { requestId: log.topics[1], templateIndex, resultHash: '0x' + data.slice(0, 64), uri: new TextDecoder('utf-8', { fatal: true }).decode(bytes), blockNumber: Number(BigInt(log.blockNumber)), logIndex: Number(BigInt(log.logIndex)), transactionHash: log.transactionHash, blockHash: log.blockHash };
}
export function safeURI(uri, gateway = 'https://ipfs.io/ipfs/') {
  try {
    let candidate = uri;
    if (uri.startsWith('ipfs://')) {
      const path = uri.slice(7).replace(/^ipfs\//, '');
      if (!/^[a-zA-Z0-9]+(?:\/[a-zA-Z0-9._~!$&'()*+,;=:@%/-]*)?$/.test(path)) return null;
      candidate = gateway + path;
    } else if (uri.startsWith('ar://')) candidate = 'https://arweave.net/' + uri.slice(5);
    const parsed = new URL(candidate);
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password) return null;
    return parsed.href;
  } catch { return null; }
}
export function formatIMD(value, precision = 4) {
  const amount = BigInt(value), scale = 10n ** 18n;
  const fraction = (amount % scale).toString().padStart(18, '0').slice(0, precision).replace(/0+$/, '');
  return (amount / scale).toLocaleString('en-US') + (fraction ? '.' + fraction : '');
}
export function countdown(eligibleAt, now) {
  const seconds = Math.max(0, Math.ceil(eligibleAt - now));
  if (seconds === 0) return 'Ready';
  return [Math.floor(seconds / 3600), Math.floor(seconds % 3600 / 60), seconds % 60].map(n => String(n).padStart(2, '0')).join(':');
}
export function newestFirst(items) { return [...items].sort((a, b) => b.blockNumber - a.blockNumber || b.logIndex - a.logIndex); }
export function mergeLogs(previous, replacements, fromBlock) {
  const records = new Map(previous.filter(x => x.blockNumber < fromBlock).map(x => [x.transactionHash + ':' + x.logIndex, x]));
  for (const item of replacements) records.set(item.transactionHash + ':' + item.logIndex, item);
  return newestFirst(records.values());
}
export async function readLogs(rpc, address, fromBlock, toBlock, progress = () => {}) {
  const result = [];
  let cursor = fromBlock, step = 10000;
  while (cursor <= toBlock) {
    const end = Math.min(toBlock, cursor + step - 1);
    let page;
    try { page = await rpc('eth_getLogs', [{ address, topics: [BUILT_TOPIC], fromBlock: hex(cursor), toBlock: hex(end) }]); }
    catch (error) { if (step <= 1) throw error; step = Math.max(1, Math.floor(step / 2)); continue; }
    for (const log of page) { const work = decodeBuilt(log); if (work) result.push(work); }
    cursor = end + 1;
    progress(end, toBlock);
  }
  return newestFirst(result);
}
export async function readStatus(rpc, config, block) {
  const tag = block.number;
  const call = (to, data) => rpc('eth_call', [{ to, data }, tag]).then(value => BigInt(value));
  const [balance, price, eligibleAt, today, nextTemplate, canCommission, workCount] = await Promise.all([
    call(IMD, SELECTORS.balanceOf + addressWord(config.workshop)),
    call(INTAKE, SELECTORS.priceOf + ACTION.slice(2) + addressWord(IMD)),
    call(config.workshop, SELECTORS.nextCommissionAt), call(config.workshop, SELECTORS.commissionsToday),
    call(config.workshop, SELECTORS.nextTemplate), call(config.workshop, SELECTORS.canCommission), call(config.workshop, SELECTORS.workCount)
  ]);
  return { balance, price, bounty: price / 50n, eligibleAt: Number(eligibleAt), today: Number(today), nextTemplate: Number(nextTemplate), canCommission: canCommission === 1n, workCount: Number(workCount), chainTime: Number(BigInt(block.timestamp)), blockNumber: Number(BigInt(tag)) };
}

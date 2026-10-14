#!/usr/bin/env node
// Publish real post-launch connection details into the static site's configuration.
//
// The Workshop address is never typed by hand: it is read from the deployed SelfHook's
// immutable `workshop()` over JSON-RPC, so web/config.json can only point at the Workshop
// the hook actually created and pays.
//
//   node scripts/configure-gallery.mjs --hook 0x... --deployment-block N [--rpc-url https://...]
//
// Node 18+ only; no packages, keys or secrets. Exits non-zero without touching config.json on any error.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const WORKSHOP_SELECTOR = '0x720c4798'; // keccak256("workshop()")[:4]
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const ZERO = /^0x0{40}$/i;

export function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (!name.startsWith('--') || i + 1 >= argv.length) throw new Error(`Unexpected argument ${name}`);
    args[name.slice(2)] = argv[i + 1];
    i += 1;
  }
  if (!ADDRESS.test(args.hook ?? '') || ZERO.test(args.hook)) throw new Error('--hook must be the nonzero 20-byte SelfHook address');
  const block = Number(args['deployment-block']);
  if (!Number.isSafeInteger(block) || block <= 0) throw new Error('--deployment-block must be the positive block number of the hook deployment');
  if (args['rpc-url'] !== undefined && !/^https?:\/\//.test(args['rpc-url'])) throw new Error('--rpc-url must be an HTTP(S) endpoint');
  return { hook: args.hook.toLowerCase(), deploymentBlock: block, rpcUrl: args['rpc-url'] };
}

async function call(rpcUrl, method, params) {
  const response = await fetch(rpcUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  if (!response.ok) throw new Error(`RPC ${method} failed with HTTP ${response.status}`);
  const body = await response.json();
  if (body.error) throw new Error(`RPC ${method} error: ${body.error.message ?? JSON.stringify(body.error)}`);
  return body.result;
}

/// Reads the Workshop the hook created, checking that both addresses carry code on the expected chain.
export async function readWorkshop(rpcUrl, hook, chainId) {
  const chain = await call(rpcUrl, 'eth_chainId', []);
  if (BigInt(chain) !== BigInt(chainId)) throw new Error(`RPC serves chain ${BigInt(chain)}, expected ${chainId}`);
  if ((await call(rpcUrl, 'eth_getCode', [hook, 'latest'])) === '0x') throw new Error('No SelfHook code at the given address');
  const raw = await call(rpcUrl, 'eth_call', [{ to: hook, data: WORKSHOP_SELECTOR }, 'latest']);
  if (typeof raw !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(raw) || !/^0x0{24}/.test(raw)) throw new Error('workshop() returned something other than an address');
  const workshop = `0x${raw.slice(26)}`.toLowerCase();
  if (ZERO.test(workshop)) throw new Error('workshop() returned the zero address');
  if ((await call(rpcUrl, 'eth_getCode', [workshop, 'latest'])) === '0x') throw new Error('No Workshop code at the address the hook reports');
  return workshop;
}

export async function configure(argv, configPath) {
  const { hook, deploymentBlock, rpcUrl } = parseArgs(argv);
  const config = JSON.parse(readFileSync(configPath, 'utf8'));
  const endpoint = rpcUrl ?? config.rpcUrl;
  const workshop = await readWorkshop(endpoint, hook, config.chainId);
  const next = { ...config, workshop, deploymentBlock };
  if (rpcUrl) next.rpcUrl = rpcUrl;
  writeFileSync(configPath, `${JSON.stringify(next, null, 2)}\n`);
  return { hook, workshop, deploymentBlock };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const configPath = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'web', 'config.json');
  configure(process.argv.slice(2), configPath)
    .then(({ hook, workshop }) => console.log(`Configured static gallery for Workshop ${workshop} read from SelfHook ${hook}`))
    .catch((error) => {
      console.error(error.message);
      process.exit(1);
    });
}

import { makeRPC, validateConfig, readStatus, readLogs, mergeLogs, safeURI, formatIMD, countdown, TEMPLATES, SELECTORS } from './chain.mjs';

const $ = id => document.getElementById(id);
let config, rpc, current, observedAt = 0, works = [], indexedThrough = null, busy = false, stale = true, sending = false;
const status = (text, error = false) => { $('connection').textContent = text; $('connection').classList.toggle('error', error); };
function stateMessage(title, text) {
  $('gallery-state').querySelector('h3').textContent = title;
  $('gallery-state').querySelector('p').textContent = text;
}
function updateClock() {
  if (!current) return;
  const now = current.chainTime + (Date.now() - observedAt) / 1000;
  const remaining = countdown(current.eligibleAt, now);
  const funded = current.balance >= current.price + current.bounty;
  $('countdown').textContent = stale ? '—' : remaining === 'Ready' && !funded ? 'Funding' : remaining;
  $('countdown-note').textContent = stale ? 'Live data is temporarily unavailable.' : !funded ? 'Waiting for enough IMD to pay for the next job.' : remaining === 'Ready' ? 'A public caller can submit the next work order.' : 'The cooldown continues across UTC midnight.';
  $('commission').disabled = stale || sending || !current.canCommission;
}
function renderStatus(value) {
  current = value; observedAt = Date.now(); stale = false;
  $('balance').replaceChildren(document.createTextNode(formatIMD(value.balance) + ' '));
  const unit = document.createElement('small'); unit.textContent = 'IMD'; $('balance').append(unit);
  $('funding-note').textContent = `Next job ${formatIMD(value.price, 8)} + caller bounty ${formatIMD(value.bounty, 8)} IMD`;
  $('today').textContent = String(value.today);
  $('next-template').textContent = 'Next work order: ' + (TEMPLATES[value.nextTemplate] || '—');
  $('commission-note').textContent = `Anyone can commission the next work and earn ${formatIMD(value.bounty, 8)} IMD. The caller pays network gas.`;
  updateClock();
}
function renderGallery() {
  $('works').replaceChildren(); $('built-count').textContent = String(works.length);
  $('gallery-state').hidden = works.length > 0;
  for (const work of works) {
    const card = document.createElement('article'); card.className = 'work-card';
    const preview = document.createElement('div'); preview.className = 'card-preview';
    const url = safeURI(work.uri, config.ipfsGateway);
    const extension = url ? new URL(url).pathname.toLowerCase() : '';
    const glyph = document.createElement('span'); glyph.className = 'card-glyph'; glyph.textContent = ['✳', '▶', 'Aa', '{ }'][work.templateIndex];
    preview.append(glyph);
    if (url && /\.(png|jpg|jpeg|webp|gif)$/.test(extension)) {
      const img = document.createElement('img'); img.loading = 'lazy'; img.referrerPolicy = 'no-referrer'; img.alt = TEMPLATES[work.templateIndex] + ' made for Self Made';
      img.onload = () => glyph.remove(); img.onerror = () => img.remove(); img.src = url; preview.append(img);
    } else if (url && /\.(mp4|webm)$/.test(extension)) {
      const video = document.createElement('video'); video.controls = true; video.preload = 'none'; video.playsInline = true;
      video.setAttribute('aria-label', 'Video made for Self Made'); video.src = url; preview.replaceChildren(video);
    }
    const body = document.createElement('div'); body.className = 'card-body';
    const meta = document.createElement('div'); meta.className = 'card-meta'; meta.textContent = `ORDER ${String(work.templateIndex + 1).padStart(2, '0')} / DELIVERED`;
    const title = document.createElement('h3'); title.textContent = TEMPLATES[work.templateIndex];
    const link = document.createElement('a'); link.target = '_blank'; link.rel = 'noopener noreferrer';
    link.href = url || `${config.explorerUrl}/tx/${work.transactionHash}`;
    link.textContent = url ? 'Open delivered work ↗' : 'View delivery onchain ↗';
    const detail = document.createElement('p'); detail.className = 'card-hash';
    detail.textContent = `Block ${work.blockNumber.toLocaleString('en-US')} · ${work.requestId.slice(0, 12)}…`;
    detail.title = `Request ${work.requestId}\nResult hash ${work.resultHash}\nURI ${work.uri}`;
    body.append(meta, title, link, detail); card.append(preview, body); $('works').append(card);
  }
}
async function refresh() {
  if (busy || !rpc) return;
  busy = true;
  try {
    const block = await rpc('eth_getBlockByNumber', ['latest', false]);
    const live = await readStatus(rpc, config, block);
    renderStatus(live); status('Live · block ' + live.blockNumber.toLocaleString('en-US'));
    const end = Math.max(config.deploymentBlock - 1, live.blockNumber - (config.confirmations ?? 2));
    // Re-read the overlap and replace it, including removals, on every refresh.
    const from = indexedThrough === null ? config.deploymentBlock : Math.max(config.deploymentBlock, Math.min(indexedThrough, end) - 20);
    if (from <= end) {
      const next = await readLogs(rpc, config.workshop, from, end, (at, target) => {
        $('history-status').textContent = at < target ? `Reading deliveries · block ${at.toLocaleString('en-US')} of ${target.toLocaleString('en-US')}` : '';
      });
      works = mergeLogs(works, next, from); indexedThrough = end; renderGallery();
    }
    if (!works.length) stateMessage('The next creation starts here.', 'No delivered work yet. Commissions rotate through memes, videos, research, and security reviews.');
    $('history-status').textContent = `${live.workCount} work orders commissioned · ${works.length} delivered · updates every ${Math.round(config.pollIntervalMs / 1000)} seconds. Links are published by Intake; external content may change or become unavailable.`;
  } catch (error) {
    stale = true; updateClock(); status('Connection interrupted · retrying', true);
    $('history-status').textContent = `Live refresh failed: ${error.message}. Previously loaded work remains visible.`;
    if (!works.length) stateMessage('Waiting for a connection.', 'The gallery will retry automatically. No wallet connection is needed to browse.');
  } finally { busy = false; }
}
$('commission').addEventListener('click', async () => {
  if (!current?.canCommission || stale || sending) return;
  sending = true; updateClock();
  try {
    if (!window.ethereum) throw new Error('Open this page in a browser with an Ethereum wallet to commission work.');
    const chain = await window.ethereum.request({ method: 'eth_chainId' });
    if (BigInt(chain) !== 4663n) throw new Error('Switch your wallet to Robinhood Chain (4663), then try again.');
    const [account] = await window.ethereum.request({ method: 'eth_requestAccounts' });
    if (!account) throw new Error('No wallet account selected.');
    const ready = await rpc('eth_call', [{ to: config.workshop, data: SELECTORS.canCommission }, 'latest']);
    if (BigInt(ready) !== 1n) throw new Error('The Workshop is no longer ready. Someone may have commissioned it already.');
    $('transaction-status').textContent = 'Confirm the commission in your wallet.';
    const tx = await window.ethereum.request({ method: 'eth_sendTransaction', params: [{ from: account, to: config.workshop, data: SELECTORS.commission }] });
    const link = document.createElement('a'); link.href = `${config.explorerUrl}/tx/${tx}`; link.target = '_blank'; link.rel = 'noopener noreferrer'; link.textContent = 'View submitted transaction ↗';
    $('transaction-status').replaceChildren(document.createTextNode('Commission submitted. '), link);
    // A submitted transaction may fail or be replaced; the gallery waits for onchain events.
    await refresh();
  } catch (error) { $('transaction-status').textContent = error.message || 'Commission was not submitted.'; }
  finally { sending = false; updateClock(); }
});
async function start() {
  try {
    const response = await fetch('./config.json', { cache: 'no-store' });
    if (!response.ok) throw new Error('Cannot load deployment configuration');
    config = await response.json();
    if (!validateConfig(config)) {
      status('Awaiting launch');
      $('countdown').textContent = 'Prelaunch';
      stateMessage('The first work is still ahead.', 'This gallery will connect to the Workshop when the launch publishes its contract address. No creations are shown before they exist.');
      $('countdown-note').textContent = 'The Workshop address is published at launch.';
      return;
    }
    rpc = makeRPC(config.rpcUrl);
    if (BigInt(await rpc('eth_chainId')) !== 4663n) throw new Error('RPC is connected to the wrong chain');
    if (await rpc('eth_getCode', [config.workshop, 'latest']) === '0x') throw new Error('No Workshop code at the configured address');
    $('contract-link').href = `${config.explorerUrl}/address/${config.workshop}`; $('contract-link').hidden = false;
    await refresh();
    setInterval(refresh, Math.max(1000, config.pollIntervalMs || 15000));
    setInterval(updateClock, 1000);
  } catch (error) { status('Configuration unavailable', true); $('history-status').textContent = error.message; stateMessage('The workshop cannot connect yet.', 'Please try again later.'); }
}
start();

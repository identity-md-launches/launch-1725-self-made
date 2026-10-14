#!/usr/bin/env python3
"""Publish real post-launch connection details into the static site's configuration."""
import argparse
import json
from pathlib import Path
import re
from urllib.parse import urlparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--workshop', required=True, help='Actual deployed Workshop address')
parser.add_argument('--deployment-block', type=int, required=True)
parser.add_argument('--rpc-url', help='Optional public browser-compatible Robinhood RPC; no API secrets')
args = parser.parse_args()
if not re.fullmatch(r'0x[0-9a-fA-F]{40}', args.workshop) or int(args.workshop, 16) == 0:
    parser.error('workshop must be a nonzero 20-byte address')
if args.deployment_block <= 0:
    parser.error('deployment-block must be the positive block number of the Workshop deployment')
if args.rpc_url and urlparse(args.rpc_url).scheme not in ('https', 'http'):
    parser.error('rpc-url must be an HTTP(S) endpoint')
path = Path(__file__).resolve().parent.parent / 'web' / 'config.json'
config = json.loads(path.read_text())
config.update(workshop=args.workshop, deploymentBlock=args.deployment_block)
if args.rpc_url:
    config['rpcUrl'] = args.rpc_url
path.write_text(json.dumps(config, indent=2) + '\n')
print('Configured static gallery for Workshop', args.workshop)

#!/bin/bash

echo "🌋 BoP Cratering Starting..."

STAGE_DIR="../cratered-$(basename $(pwd))-$(date +%s)"
mkdir "$STAGE_DIR"

echo "📜 Purifying with rsync..."
rsync -av --exclude-from='.ipfsignore' ./ "$STAGE_DIR/"

cd "$STAGE_DIR"

echo "🌐 Adding to IPFS..."
ipfs add -r . | tee cratered-cid.txt

echo "✅ Crater complete. CID stored in cratered-cid.txt."

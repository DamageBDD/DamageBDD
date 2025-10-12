#!/bin/sh
set -eu

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends software-properties-common
add-apt-repository -y ppa:twdragon/ipfs
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y ipfs-kubo

exit 0

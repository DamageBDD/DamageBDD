#!/bin/sh
lightningd --conf=etc/cln.conf \
--log-file=$PWD/logs/lightning.log \
 --bitcoin-rpcpassword=$(pass asyncmind/bitcoin/password)

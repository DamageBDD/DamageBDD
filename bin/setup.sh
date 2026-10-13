#!/bin/sh -x
sudo groupadd --system damage
sudo useradd --system --create-home \
  --gid damage \
  --shell /usr/bin/nologin \
  --comment "User for DamageBDD system service" \
  damage


sudo mkdir -p /var/lib/damagebdd/sshtest_user/.ssh 
sudo chown damage:damage /var/lib/damagebdd/ -R
sudo chown steven:steven /var/lib/damagebdd/ -R
ssh-keygen -t rsa -f /var/lib/damagebdd/ssh_daemon/ssh_host_rsa_key
ipfs get Qmehdmv1CT7qXbmSHp31at6GhkyPhAnj2ePYCfvXzPDkZC bin/lightpanda-x86_64-linux


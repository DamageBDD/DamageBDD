docker run --rm -it \
  -v "$(pwd)/deb:/deb" \
  -w /opt/workspace \
  damagebdd/mint22-builder:latest \
  bash -xlc '
 set -e
    #apt-get update -y
    apt-get install -y /deb/damage_*.deb     # install your deb package
    dpkg -L damage
    /opt/damage/bin/damage foreground
'

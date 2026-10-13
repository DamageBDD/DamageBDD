  #-v "$(pwd)/../../../:/opt/workspace" \
docker run  -it \
  -v "$(pwd)/deb:/deb" \
  -w /opt/workspace \
    -p 8888:8080 \
  linuxmintd/mint22-amd64 \
  bash -xlc '
    set -e
    # apt-get update -y
    # bash
    PKG_DEBUG=1 dpkg -i -D3 /deb/damage_*.deb

    #apt-get install -y /deb/damage_*.deb
    #dpkg -L damage
    export SHELL=sh
    bash
    /opt/damage/bin/damage foreground

'

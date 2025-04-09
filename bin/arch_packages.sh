sudo pacman -S --needed \
     erlang \
     pinentry \
     gnupg \
     kubo \
     bitcoin-daemon \
     libyaml

if ! command -v yay &> /dev/null; then
  echo "yay not found. Installing yay..."
  sudo pacman -S --needed git base-devel
  git clone https://aur.archlinux.org/yay-bin.git
  cd yay-bin
  makepkg -si
  cd ..
  rm -rf yay-bin
else
  echo "yay is already installed."
fi

yay -S \
    core-lightning
     

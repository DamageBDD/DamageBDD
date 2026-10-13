#!/usr/bin/env sh

PROJECT_NAME="damagebdd"
PUBLISH_FILE="scripts/publish.el"
mkdir -p public

# Normalize PWD for Docker on Windows (Git Bash/WSL compatible)
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    PROJECT_DIR=$(pwd -W 2>/dev/null || pwd) # Git Bash & MSYS
    ;;
  *)
    PROJECT_DIR=$(pwd)
    ;;
esac

# Check for emacs
if command -v emacs >/dev/null 2>&1; then
  echo "Emacs found. Running locally..."
  emacs --batch \
        -l "$PUBLISH_FILE" \
        --eval "(damagebdd-publish)"

# Fallback to Docker
elif command -v docker >/dev/null 2>&1; then
  echo "Emacs not found. Running with Docker..."
  docker run --rm \
    -v "$PROJECT_DIR":/project \
    -w /project \
    silex/emacs:latest \
    emacs --batch \
          -l /project/"$PUBLISH_FILE" \
          --eval "(damagebdd-publish)"

else
  echo "Error: Neither Emacs nor Docker is available." >&2
  exit 1
fi

sync_to_nginx() {
  echo "Syncing to Nginx..."
  sudo rsync -av --delete "$PROJECT_DIR/public/" /var/www/damagebdd/
}


if [ "$1" = "sync" ]; then
  sync_to_nginx
fi

sync_to_nginx_prod() {
  echo "Syncing to Nginx Prod..."
  rsync -avz --delete -e ssh public/ root@node0:/var/www/damagebdd/
}
if [ "$1" = "sync_prod" ]; then
  sync_to_nginx_prod
fi

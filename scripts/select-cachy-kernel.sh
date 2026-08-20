#!/usr/bin/env bash

# FEDORA_POST_INSTALL_MANAGED
# Helper appelé après une transaction DNF concernant un noyau. Il sélectionne
# le dernier noyau CachyOS uniquement après des contrôles stricts. L'absence de
# noyau CachyOS n'est pas une erreur afin de ne pas casser une transaction DNF.

set -Eeuo pipefail
IFS=$'\n\t'

log() {
  local message="[fedora-post-install] $*"
  printf '%s\n' "$message"
  command -v logger >/dev/null 2>&1 && logger -t fedora-post-install -- "$*" || true
}

command -v grubby >/dev/null 2>&1 || {
  log "grubby est introuvable ; sélection du noyau ignorée."
  exit 0
}

candidate="$(
  grubby --info=ALL 2>/dev/null |
    awk -F= '$1 == "kernel" {gsub(/"/, "", $2); if (tolower($2) ~ /cachy/) print $2}' |
    sort -V |
    tail -n 1
)"

if [[ -z "$candidate" ]]; then
  log "Aucun noyau CachyOS trouvé ; noyau par défaut inchangé."
  exit 0
fi

case "$candidate" in
  /boot/vmlinuz-*cachy* | /boot/vmlinuz-*cachyos*) ;;
  *)
    log "Chemin CachyOS inattendu refusé : $candidate"
    exit 0
    ;;
esac

if [[ ! -f "$candidate" || -L "$candidate" ]]; then
  log "Le noyau candidat n'est pas un fichier régulier : $candidate"
  exit 0
fi

grubby --set-default "$candidate"
log "Noyau CachyOS défini par défaut : $candidate"

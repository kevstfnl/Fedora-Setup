#!/usr/bin/env bash

# Désinstallation autonome et prudente du parcours CachyOS installé par
# fedora-setup.sh. Le script revient toujours sur Fedora avant de supprimer le
# moindre noyau CachyOS.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

# shellcheck source=../lib/common.sh
source "$PROJECT_DIR/lib/common.sh"

DRY_RUN=false
RESUME=false

readonly CACHYOS_COPR="bieszczaders/kernel-cachyos"
readonly CACHYOS_ADDONS_COPR="bieszczaders/kernel-cachyos-addons"
readonly CACHYOS_HELPER_TARGET="/usr/local/libexec/fedora-post-install/select-cachy-kernel"
readonly CACHYOS_ACTION_TARGET="/etc/dnf/libdnf5-plugins/actions.d/cachy-default.actions"

usage() {
  cat <<'EOF'
Usage :
  ./scripts/uninstall-cachyos.sh [--dry-run] [--resume] [--help]

Le script :
  1. sélectionne un noyau Fedora ;
  2. exige un redémarrage sur Fedora si CachyOS est en cours d'utilisation ;
  3. restaure les addons, ZRAM, GRUB et SELinux ;
  4. retire uniquement les paquets et fichiers CachyOS validés.
EOF
}

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --resume)
        RESUME=true
        shift
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        printf 'Option inconnue : %s\n' "$1" >&2
        usage >&2
        return 1
        ;;
    esac
  done
}

validate_fedora_host() {
  require_non_root
  require_command sudo
  require_command rpm
  require_command dnf
  require_command grubby
  [[ -f /etc/os-release ]] || die "/etc/os-release est absent."
  grep -q '^ID=fedora$' /etc/os-release || die "Ce désinstallateur cible uniquement Fedora."
  [[ ! -e /run/ostree-booted ]] || die "Les éditions Atomic ne sont pas prises en charge."

  if ! is_true "$DRY_RUN"; then
    run_cmd "Validation de l'accès sudo" sudo -v
  fi
}

set_fedora_kernel_default() {
  local fedora_kernel
  fedora_kernel="$(latest_fedora_kernel)"
  validate_kernel_path "$fedora_kernel" ||
    die "Aucun noyau Fedora régulier et amorçable n'a été trouvé."
  state_set uninstall_fedora_kernel "$fedora_kernel"
  run_cmd "Sélection du noyau Fedora de secours" sudo grubby --set-default "$fedora_kernel"
  log_ok "Noyau Fedora retenu : $fedora_kernel"
}

ensure_running_fedora() {
  local running_kernel="$(uname -r)"
  if [[ "${running_kernel,,}" != *cachy* ]]; then
    log_ok "Le noyau courant est Fedora : $running_kernel"
    return 0
  fi

  log_warn "Le système tourne encore sur CachyOS : $running_kernel"
  state_set resume_required uninstall-cachyos-fedora-boot

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Un redémarrage sur Fedora serait exigé avant toute suppression."
    return 0
  fi

  if confirm_action sensitive "Redémarrer maintenant sur le noyau Fedora sélectionné ?"; then
    run_cmd "Redémarrage sur Fedora" sudo systemctl reboot
  else
    log_warn "Aucun paquet n'a été supprimé. Redémarrez sur Fedora puis relancez avec --resume."
  fi
  exit 0
}

remove_project_hooks() {
  remove_managed_file "$CACHYOS_ACTION_TARGET"
  remove_managed_file "$CACHYOS_HELPER_TARGET"
}

restore_ananicy_state() {
  local installed_before enabled_before active_before
  installed_before="$(state_get cachyos_ananicy_installed_before unknown)"
  enabled_before="$(state_get cachyos_ananicy_enabled_before disabled)"
  active_before="$(state_get cachyos_ananicy_active_before inactive)"

  if package_installed ananicy-cpp; then
    if [[ "$active_before" != "active" ]]; then
      run_cmd "Restauration de l'état arrêté d'Ananicy" sudo systemctl stop ananicy-cpp
    fi
    if [[ "$enabled_before" != "enabled" ]]; then
      run_cmd "Restauration de l'état désactivé d'Ananicy" sudo systemctl disable ananicy-cpp
    fi
  fi

  log_info "État Ananicy avant installation : installé=$installed_before, activé=$enabled_before, actif=$active_before"
}

restore_zram() {
  if [[ "$(state_get cachyos_zram_swapped false)" != "true" ]]; then
    log_info "Aucun remplacement ZRAM enregistré par le projet."
    return 0
  fi

  package_installed cachyos-settings || {
    log_warn "cachyos-settings est déjà absent ; restauration ZRAM à vérifier manuellement."
    return 0
  }

  confirm_action sensitive "Restaurer zram-generator-defaults à la place de cachyos-settings ?" ||
    die "La restauration ZRAM est nécessaire avant de poursuivre."
  run_cmd "Restauration de la configuration ZRAM Fedora" sudo dnf swap cachyos-settings zram-generator-defaults
  run_cmd "Régénération de l'initramfs Fedora" sudo dracut -f
}

remove_added_addon_packages() {
  local encoded
  encoded="$(state_get cachyos_added_addon_packages)"
  if [[ -z "$encoded" ]]; then
    log_info "Aucun paquet addon ajouté par le projet n'est enregistré."
    return 0
  fi

  local -a recorded=()
  local -a installed=()
  local package
  IFS=' ' read -r -a recorded <<<"$encoded"

  for package in "${recorded[@]}"; do
    [[ "$package" =~ ^[a-zA-Z0-9._+-]+$ ]] ||
      die "Nom de paquet addon invalide dans l'état : $package"
    package_installed "$package" && installed+=("$package")
  done

  (("${#installed[@]}" > 0)) || {
    log_ok "Les addons ajoutés par le projet sont déjà absents."
    return 0
  }

  confirm_action sensitive "Supprimer les addons CachyOS ajoutés : ${installed[*]} ?" ||
    die "Suppression des addons refusée."
  run_cmd "Suppression des addons CachyOS" sudo dnf remove "${installed[@]}"
}

copr_repo_present() {
  local project_name="$1"
  dnf repolist --all 2>/dev/null | grep -Fq "${project_name//\//:}"
}

remove_copr_if_present() {
  local project_name="$1"
  if copr_repo_present "$project_name"; then
    run_cmd "Suppression du COPR $project_name" sudo dnf copr remove "$project_name"
  else
    log_ok "COPR déjà absent : $project_name"
  fi
}

restore_addons() {
  restore_ananicy_state
  restore_zram
  remove_added_addon_packages
  remove_copr_if_present "$CACHYOS_ADDONS_COPR"
}

list_installed_cachy_kernel_packages() {
  rpm -qa --qf '%{NAME}\n' |
    sort -u |
    awk '/^kernel-cachyos([A-Za-z0-9._+-]*)?$/ {print}'
}

remove_cachy_kernel_packages() {
  local -a packages=()
  mapfile -t packages < <(list_installed_cachy_kernel_packages)

  if (("${#packages[@]}" == 0)); then
    log_ok "Aucun paquet de noyau CachyOS n'est installé."
    return 0
  fi

  local package
  for package in "${packages[@]}"; do
    [[ "$package" =~ ^kernel-cachyos[A-Za-z0-9._+-]*$ ]] ||
      die "Nom de paquet noyau inattendu : $package"
  done

  confirm_action sensitive "Supprimer les paquets noyau CachyOS : ${packages[*]} ?" ||
    die "Suppression du noyau CachyOS refusée."
  run_cmd "Suppression des noyaux CachyOS" sudo dnf remove "${packages[@]}"
}

restore_grub_default_setting() {
  [[ "$(state_get cachyos_grub_default_changed false)" == "true" ]] || return 0
  local original
  original="$(state_get cachyos_grub_default_before __missing__)"
  local temporary="$RUNTIME_TMP/grub-default-restored"

  awk -v original="$original" '
    BEGIN {done = 0}
    /^GRUB_DEFAULT=/ && !done {
      if (original != "__missing__") print original
      done = 1
      next
    }
    {print}
    END {
      if (!done && original != "__missing__") print original
    }
  ' /etc/default/grub >"$temporary"
  run_cmd "Restauration de GRUB_DEFAULT" sudo install -o root -g root -m 0644 "$temporary" /etc/default/grub
}

restore_selinux_boolean() {
  if [[ "$(state_get cachyos_selinux_changed false)" == "true" &&
    "$(state_get cachyos_selinux_before)" == "off" ]]; then
    run_cmd "Restauration du booléen SELinux" sudo setsebool -P domain_kernel_load_modules off
  fi
}

verify_uninstall() {
  if list_installed_cachy_kernel_packages | grep -q .; then
    die "Des paquets de noyau CachyOS sont encore installés."
  fi
  [[ ! -e "$CACHYOS_ACTION_TARGET" ]] || die "L'action DNF5 CachyOS existe encore."
  [[ ! -e "$CACHYOS_HELPER_TARGET" ]] || die "Le helper CachyOS existe encore."

  local selected
  selected="$(sudo grubby --default-kernel)"
  [[ "${selected,,}" != *cachy* ]] || die "Le noyau par défaut est toujours CachyOS."
  validate_kernel_path "$selected" || die "Le noyau Fedora par défaut n'est pas valide : $selected"
  log_ok "Désinstallation validée ; noyau par défaut : $selected"
}

main() {
  parse_arguments "$@"
  init_runtime uninstall-cachyos
  log_step "Désinstallation sécurisée de CachyOS"
  validate_fedora_host

  local pending="$(state_get resume_required)"
  if [[ "$pending" == "uninstall-cachyos-fedora-boot" && "$RESUME" != "true" ]]; then
    die "Un redémarrage sur Fedora est attendu. Relancez avec --resume."
  fi

  set_fedora_kernel_default
  ensure_running_fedora

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Simulation de la restauration des hooks, addons, ZRAM, noyaux, GRUB et SELinux."
  fi

  remove_project_hooks
  restore_addons
  remove_cachy_kernel_packages
  remove_copr_if_present "$CACHYOS_COPR"
  restore_grub_default_setting
  restore_selinux_boolean

  if ! is_true "$DRY_RUN"; then
    set_fedora_kernel_default
    verify_uninstall
    state_set resume_required ""
    state_mark_step cachyos.uninstalled
  fi

  log_ok "Procédure de désinstallation CachyOS terminée."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

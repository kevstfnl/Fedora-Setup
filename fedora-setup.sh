#!/usr/bin/env bash

# Point d'entrée du post-install Fedora. Les opérations sont réparties dans
# lib/tasks.sh et lib/cachyos.sh pour garder ce fichier centré sur l'expérience
# utilisateur, la configuration et l'orchestration.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/tasks.sh
source "$SCRIPT_DIR/lib/tasks.sh"
# shellcheck source=lib/cachyos.sh
source "$SCRIPT_DIR/lib/cachyos.sh"

readonly PROGRAM_VERSION="1.0.0"

CONFIG_PATH="$SCRIPT_DIR/config.ini"
RESUME=false
VALIDATE_CONFIG_ONLY=false
declare -a CONFIG_OVERRIDES=()
declare -a ONLY_STAGES=()
declare -a SKIPPED_STAGES=()

usage() {
  cat <<'EOF'
Usage :
  ./fedora-setup.sh [options]

Options :
  --config CHEMIN       Utiliser un autre fichier de configuration.
  --set CLE=VALEUR      Surcharger une option (répétable).
  --dry-run             Afficher les opérations sans modifier le système.
  --resume              Reprendre après une interruption ou un redémarrage.
  --only ETAPE          Exécuter seulement une étape (répétable).
  --skip ETAPE          Ignorer une étape (répétable).
  --validate-config     Valider la configuration puis quitter.
  --version             Afficher la version.
  --help                Afficher cette aide.

Étapes :
  prepare, repositories, desktop, apps, development, gaming, cachyos, validation

Exemples :
  ./fedora-setup.sh --config ./config.ini --dry-run
  ./fedora-setup.sh --resume
  ./fedora-setup.sh --only apps --only development
  ./fedora-setup.sh --set INSTALL_CACHYOS=true
EOF
}

normalize_stage() {
  case "$1" in
    1 | prepare) printf 'prepare' ;;
    2 | repositories | repos) printf 'repositories' ;;
    3 | desktop | gnome) printf 'desktop' ;;
    4 | apps | applications) printf 'apps' ;;
    5 | development | dev) printf 'development' ;;
    6 | gaming | games) printf 'gaming' ;;
    7 | cachyos) printf 'cachyos' ;;
    8 | validation | validate) printf 'validation' ;;
    *)
      printf 'Étape inconnue : %s\n' "$1" >&2
      return 1
      ;;
  esac
}

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      --config)
        (($# >= 2)) || {
          printf '%s\n' "--config attend un chemin." >&2
          return 1
        }
        CONFIG_PATH="$2"
        shift 2
        ;;
      --set)
        (($# >= 2)) || {
          printf '%s\n' "--set attend CLE=VALEUR." >&2
          return 1
        }
        CONFIG_OVERRIDES+=("$2")
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --resume)
        RESUME=true
        shift
        ;;
      --only)
        (($# >= 2)) || {
          printf '%s\n' "--only attend une étape." >&2
          return 1
        }
        ONLY_STAGES+=("$(normalize_stage "$2")")
        shift 2
        ;;
      --skip)
        (($# >= 2)) || {
          printf '%s\n' "--skip attend une étape." >&2
          return 1
        }
        SKIPPED_STAGES+=("$(normalize_stage "$2")")
        shift 2
        ;;
      --validate-config)
        VALIDATE_CONFIG_ONLY=true
        shift
        ;;
      --version)
        printf 'fedora-setup %s\n' "$PROGRAM_VERSION"
        exit 0
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        printf 'Option inconnue : %s\n\n' "$1" >&2
        usage >&2
        return 1
        ;;
    esac
  done
}

contains_value() {
  local expected="$1"
  shift
  local value
  for value in "$@"; do
    [[ "$value" == "$expected" ]] && return 0
  done
  return 1
}

stage_is_selected() {
  local stage="$1"

  if contains_value "$stage" "${SKIPPED_STAGES[@]}"; then
    return 1
  fi
  (("${#ONLY_STAGES[@]}" == 0)) && return 0
  contains_value "$stage" "${ONLY_STAGES[@]}"
}

print_boolean_choice() {
  local label="$1"
  local value="$2"
  if [[ "$value" == "true" ]]; then
    log_info "  ✓ $label"
  else
    log_info "  – $label"
  fi
}

print_execution_plan() {
  log_step "Plan d'exécution"
  log_info "Configuration : $CONFIG_PATH"
  log_info "Fedora ciblée : Workstation 44 x86_64"
  log_info "Mode dry-run : $DRY_RUN"
  log_info "Reprise : $RESUME"
  log_info "Confirmation automatique des actions sûres : $AUTO_CONFIRM_SAFE_ACTIONS"
  log_info "Redémarrage automatique : $AUTO_REBOOT"

  log_info "Applications personnelles :"
  print_boolean_choice "Brave" "$INSTALL_BRAVE"
  print_boolean_choice "Bitwarden" "$INSTALL_BITWARDEN"
  print_boolean_choice "ClamAV" "$INSTALL_CLAMAV"
  print_boolean_choice "ClamUI" "$INSTALL_CLAMUI"
  print_boolean_choice "Pinta" "$INSTALL_PINTA"
  print_boolean_choice "Upscayl" "$INSTALL_UPSCAYL"
  print_boolean_choice "MPV" "$INSTALL_MPV"
  print_boolean_choice "RustDesk" "$INSTALL_RUSTDESK"
  print_boolean_choice "Gear Lever" "$INSTALL_GEARLEVER"

  log_info "Développement :"
  print_boolean_choice "Visual Studio Code" "$INSTALL_VSCODE"
  print_boolean_choice "Desktop Plus" "$INSTALL_DESKTOP_PLUS"
  print_boolean_choice "Bruno" "$INSTALL_BRUNO"
  print_boolean_choice "Docker Engine" "$INSTALL_DOCKER"
  print_boolean_choice "Node.js 24 LTS + pnpm" "$INSTALL_NODE"
  print_boolean_choice "RTK" "$INSTALL_RTK"
  print_boolean_choice "Outils CLI" "$INSTALL_CLI_TOOLS"

  log_info "Jeux :"
  print_boolean_choice "Steam" "$INSTALL_STEAM"
  print_boolean_choice "Bottles" "$INSTALL_BOTTLES"
  print_boolean_choice "Lutris" "$INSTALL_LUTRIS"
  print_boolean_choice "Heroic" "$INSTALL_HEROIC"
  print_boolean_choice "GameMode" "$INSTALL_GAMEMODE"
  print_boolean_choice "Gamescope" "$INSTALL_GAMESCOPE"

  log_info "Pilote NVIDIA : $NVIDIA_DRIVER"
  print_boolean_choice "Codecs et accélération matérielle" "$INSTALL_HARDWARE_CODECS"
  print_boolean_choice "Noyau CachyOS expérimental" "$INSTALL_CACHYOS"
  if [[ "$INSTALL_CACHYOS" == "true" ]]; then
    print_boolean_choice "Addons CachyOS" "$INSTALL_CACHYOS_ADDONS"
  fi
}

load_configuration() {
  set_config_defaults
  parse_config_file "$CONFIG_PATH"

  local override
  for override in "${CONFIG_OVERRIDES[@]}"; do
    apply_config_override "$override"
  done

  resolve_config_dependencies
}

check_resume_contract() {
  local pending
  pending="$(state_get resume_required)"

  if [[ -n "$pending" && "$RESUME" != "true" ]]; then
    die "Une reprise est attendue au point « $pending ». Relancez avec --resume."
    return 1
  fi

  if [[ "$RESUME" == "true" ]]; then
    if [[ -n "$pending" ]]; then
      log_info "Reprise du point enregistré : $pending"
    else
      log_warn "--resume a été demandé, mais aucun redémarrage n'était en attente."
    fi
  fi
}

run_selected_stage() {
  local stage="$1"
  local label="$2"
  local function_name="$3"

  if ! stage_is_selected "$stage"; then
    log_info "Étape ignorée par la sélection : $label"
    return 0
  fi

  log_step "$label"
  "$function_name"
}

main() {
  parse_arguments "$@"
  load_configuration

  if [[ "$VALIDATE_CONFIG_ONLY" == "true" ]]; then
    printf 'Configuration valide : %s\n' "$CONFIG_PATH"
    return 0
  fi

  init_runtime main
  log_info "Fedora Setup $PROGRAM_VERSION démarre."
  check_resume_contract
  print_execution_plan
  system_preflight

  local config_hash
  config_hash="$(sha256sum "$CONFIG_PATH" | awk '{print $1}')"
  state_set config_sha256 "$config_hash"

  run_selected_stage prepare "Étape 1/8 — Préparation et mise à jour" stage_prepare
  run_selected_stage repositories "Étape 2/8 — Dépôts, codecs et pilotes" stage_repositories_and_drivers
  run_selected_stage desktop "Étape 3/8 — GNOME, shell et polices" stage_desktop
  run_selected_stage apps "Étape 4/8 — Applications personnelles" stage_apps
  run_selected_stage development "Étape 5/8 — Environnement de travail" stage_development
  run_selected_stage gaming "Étape 6/8 — Jeux" stage_gaming
  run_selected_stage cachyos "Étape 7/8 — CachyOS expérimental" stage_cachyos
  run_selected_stage validation "Étape 8/8 — Validation finale" stage_validation

  state_set resume_required ""
  state_set last_success "$(date --iso-8601=seconds)"
  log_ok "Post-installation terminée. Consultez le résumé ci-dessus et $LOG_FILE."

  if [[ "$(state_get reboot_recommended false)" == "true" ]]; then
    request_configured_reboot final "Un redémarrage est recommandé pour appliquer tous les changements."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

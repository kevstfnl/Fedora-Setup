#!/usr/bin/env bash

# Fonctions communes au script principal et au désinstallateur CachyOS.
# Ce fichier est chargé avec source uniquement depuis le dépôt : il ne lit jamais
# config.ini comme du code.

set -Eeuo pipefail
IFS=$'\n\t'

readonly PROJECT_NAME="fedora-post-install"
readonly MANAGED_MARKER="FEDORA_POST_INSTALL_MANAGED"

DRY_RUN="${DRY_RUN:-false}"
AUTO_CONFIRM_SAFE_ACTIONS="${AUTO_CONFIRM_SAFE_ACTIONS:-false}"
AUTO_CONFIRM_ALL_ACTIONS="${AUTO_CONFIRM_ALL_ACTIONS:-false}"
STATE_ROOT="${STATE_ROOT:-}"
STATE_STEPS_DIR="${STATE_STEPS_DIR:-}"
STATE_VALUES_DIR="${STATE_VALUES_DIR:-}"
LOG_FILE="${LOG_FILE:-}"
RUNTIME_TMP="${RUNTIME_TMP:-}"

color_enabled() {
  [[ -t 1 && -z "${NO_COLOR:-}" ]]
}

level_color() {
  case "$1" in
    INFO) printf '\033[1;34m' ;;
    OK) printf '\033[1;32m' ;;
    WARN) printf '\033[1;33m' ;;
    ERROR) printf '\033[1;31m' ;;
    STEP) printf '\033[1;35m' ;;
    CMD) printf '\033[0;36m' ;;
    *) printf '\033[0m' ;;
  esac
}

log_message() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  if color_enabled; then
    printf '%b[%s] %-5s%b %s\n' "$(level_color "$level")" "$timestamp" "$level" '\033[0m' "$message"
  else
    printf '[%s] %-5s %s\n' "$timestamp" "$level" "$message"
  fi

  if [[ -n "$LOG_FILE" ]]; then
    printf '[%s] %-5s %s\n' "$timestamp" "$level" "$message" >>"$LOG_FILE"
  fi
}

log_info() { log_message INFO "$@"; }
log_ok() { log_message OK "$@"; }
log_warn() { log_message WARN "$@"; }
log_error() { log_message ERROR "$@"; }
log_step() {
  printf '\n'
  log_message STEP "$@"
}

die() {
  log_error "$*"
  return 1
}

is_true() {
  [[ "${1:-false}" == "true" ]]
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

render_command() {
  local rendered=""
  local argument
  for argument in "$@"; do
    printf -v rendered '%s%q ' "$rendered" "$argument"
  done
  printf '%s' "${rendered% }"
}

run_cmd() {
  local description="$1"
  shift

  log_info "$description"
  log_message CMD "$(render_command "$@")"

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Commande non exécutée."
    return 0
  fi

  local rc
  if "$@" 2>&1 | tee -a "$LOG_FILE"; then
    log_ok "$description : terminé."
    return 0
  else
    local -a pipeline_status=("${PIPESTATUS[@]}")
    rc="${pipeline_status[0]}"
    log_error "$description : échec (code $rc)."
    return "$rc"
  fi
}

run_stateful_cmd() {
  local description="$1"
  shift

  log_info "$description"
  log_message CMD "$(render_command "$@")"

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Commande non exécutée."
    return 0
  fi

  # Une fonction comme `nvm use` doit modifier le shell courant. Un pipeline
  # vers tee l'exécuterait dans un sous-shell et perdrait notamment son PATH.
  local output_file="$RUNTIME_TMP/stateful-$(date +%s%N).log"
  local rc
  if "$@" >"$output_file" 2>&1; then
    tee -a "$LOG_FILE" <"$output_file"
    log_ok "$description : terminé."
    return 0
  else
    rc=$?
  fi

  tee -a "$LOG_FILE" <"$output_file"
  log_error "$description : échec (code $rc)."
  return "$rc"
}

run_quiet() {
  local description="$1"
  shift

  log_info "$description"
  log_message CMD "$(render_command "$@")"

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Commande non exécutée."
    return 0
  fi

  local rc
  if "$@" >>"$LOG_FILE" 2>&1; then
    log_ok "$description : terminé."
    return 0
  else
    rc=$?
  fi

  log_error "$description : échec (code $rc). Consultez $LOG_FILE."
  return "$rc"
}

confirm_action() {
  local sensitivity="$1"
  local prompt="$2"

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Confirmation qui serait demandée ($sensitivity) : $prompt"
    return 0
  fi

  if is_true "$AUTO_CONFIRM_ALL_ACTIONS"; then
    log_warn "Confirmation automatique complète ($sensitivity) : $prompt"
    return 0
  fi

  if [[ "$sensitivity" == "safe" ]] && is_true "$AUTO_CONFIRM_SAFE_ACTIONS"; then
    log_info "Confirmation automatique : $prompt"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    die "Une confirmation interactive est nécessaire : $prompt"
    return 1
  fi

  local answer
  printf '%s [y/N] ' "$prompt"
  read -r answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

cleanup_runtime() {
  if [[ -z "$RUNTIME_TMP" ]]; then
    return
  fi

  case "$RUNTIME_TMP" in
    /tmp/fedora-post-install.*)
      if [[ -d "$RUNTIME_TMP" && ! -L "$RUNTIME_TMP" ]]; then
        rm -rf -- "$RUNTIME_TMP"
      fi
      ;;
    *)
      log_warn "Répertoire temporaire inattendu non supprimé : $RUNTIME_TMP"
      ;;
  esac
}

handle_signal() {
  log_warn "Interruption reçue. Les opérations déjà validées restent enregistrées."
  exit 130
}

init_runtime() {
  local component="$1"
  local state_home="${XDG_STATE_HOME:-$HOME/.local/state}"

  STATE_ROOT="$state_home/$PROJECT_NAME"
  STATE_STEPS_DIR="$STATE_ROOT/steps"
  STATE_VALUES_DIR="$STATE_ROOT/values"

  mkdir -p -m 0700 "$STATE_STEPS_DIR" "$STATE_VALUES_DIR"
  LOG_FILE="$STATE_ROOT/${component}.log"
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"

  exec 9>"$STATE_ROOT/run.lock"
  if ! flock -n 9; then
    die "Une autre instance du projet utilise déjà $STATE_ROOT."
    return 1
  fi

  RUNTIME_TMP="$(mktemp -d /tmp/fedora-post-install.XXXXXX)"
  [[ -n "$RUNTIME_TMP" && -d "$RUNTIME_TMP" && ! -L "$RUNTIME_TMP" ]] ||
    die "Impossible de créer un répertoire temporaire sûr."

  trap cleanup_runtime EXIT
  trap handle_signal INT TERM

  log_info "Journal détaillé : $LOG_FILE"
  log_info "État persistant : $STATE_ROOT"
  if is_true "$DRY_RUN"; then
    log_warn "Mode dry-run actif : aucune commande de modification ne sera exécutée."
  fi
}

state_key_is_valid() {
  [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ ]]
}

state_set() {
  local key="$1"
  local value="$2"

  state_key_is_valid "$key" || {
    die "Clé d'état invalide : $key"
    return 1
  }
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
    die "Une valeur d'état ne peut pas contenir de retour à la ligne : $key"
    return 1
  }

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] État $key=$value"
    return 0
  fi

  local temporary
  temporary="$(mktemp "$STATE_VALUES_DIR/.value.XXXXXX")"
  printf '%s\n' "$value" >"$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$STATE_VALUES_DIR/$key"
}

state_get() {
  local key="$1"
  local default_value="${2:-}"
  local path="$STATE_VALUES_DIR/$key"

  if [[ -f "$path" && ! -L "$path" ]]; then
    IFS= read -r value <"$path" || true
    printf '%s' "${value:-}"
  else
    printf '%s' "$default_value"
  fi
}

state_mark_step() {
  local step="$1"
  state_key_is_valid "$step" || {
    die "Identifiant d'étape invalide : $step"
    return 1
  }

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] L'étape $step serait marquée comme terminée."
    return 0
  fi

  local temporary
  temporary="$(mktemp "$STATE_STEPS_DIR/.step.XXXXXX")"
  printf '%s\n' "$(date --iso-8601=seconds)" >"$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$STATE_STEPS_DIR/$step"
}

state_step_done() {
  [[ -f "$STATE_STEPS_DIR/$1" && ! -L "$STATE_STEPS_DIR/$1" ]]
}

run_step_once() {
  local step="$1"
  local description="$2"
  local function_name="$3"

  if state_step_done "$step"; then
    log_ok "Déjà validé : $description"
    return 0
  fi

  log_step "$description"
  "$function_name"
  state_mark_step "$step"
  log_ok "Étape validée : $description"
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || {
    die "Commande requise introuvable : $command_name"
    return 1
  }
}

require_non_root() {
  if ((EUID == 0)); then
    die "Exécutez ce script comme utilisateur normal, sans sudo."
    return 1
  fi
}

install_managed_content() {
  local target="$1"
  local mode="$2"
  local content="$3"
  local temporary="$RUNTIME_TMP/managed-$(date +%s%N)"

  printf '%s' "$content" >"$temporary"
  chmod "$mode" "$temporary"
  run_cmd "Installation du fichier géré $target" sudo install -D -o root -g root -m "$mode" "$temporary" "$target"
}

remove_managed_file() {
  local target="$1"

  [[ -e "$target" || -L "$target" ]] || return 0
  [[ -f "$target" && ! -L "$target" ]] || {
    die "La cible gérée n'est pas un fichier régulier : $target"
    return 1
  }
  grep -Fq "$MANAGED_MARKER" "$target" || {
    die "Refus de supprimer un fichier non signé par le projet : $target"
    return 1
  }
  run_cmd "Suppression du fichier géré $target" sudo rm -f -- "$target"
}

package_installed() {
  rpm -q -- "$1" >/dev/null 2>&1
}

package_available() {
  dnf repoquery --available --latest-limit 1 "$1" 2>/dev/null | grep -q .
}

run_safe_dnf() {
  local description="$1"
  shift
  local -a command=(sudo dnf)

  # La confirmation fonctionnelle a déjà été gérée par confirm_action safe.
  # Lorsque l'utilisateur a demandé l'automatisation, éviter que DNF repose
  # ensuite la même question pour chaque transaction ordinaire.
  if is_true "$AUTO_CONFIRM_SAFE_ACTIONS" || is_true "$AUTO_CONFIRM_ALL_ACTIONS"; then
    command+=(--assumeyes)
  fi
  command+=("$@")
  run_cmd "$description" "${command[@]}"
}

run_sensitive_dnf() {
  local description="$1"
  shift
  local -a command=(sudo dnf)

  # Le mode complet est un choix explicite de l'utilisateur. Sans lui, DNF
  # conserve sa propre confirmation pour les dépôts, swaps et suppressions.
  if is_true "$AUTO_CONFIRM_ALL_ACTIONS"; then
    command+=(--assumeyes)
  fi
  command+=("$@")
  run_cmd "$description" "${command[@]}"
}

ensure_dnf_packages() {
  local -a missing=()
  local package

  for package in "$@"; do
    if package_installed "$package"; then
      log_ok "Paquet déjà installé : $package"
    elif package_available "$package"; then
      missing+=("$package")
    elif is_true "$DRY_RUN"; then
      log_warn "[dry-run] $package n'est pas visible dans les dépôts actuellement actifs ; il sera revérifié après leur activation."
      missing+=("$package")
    else
      die "Paquet indisponible dans les dépôts actifs : $package"
      return 1
    fi
  done

  (("${#missing[@]}" > 0)) || return 0
  confirm_action safe "Installer les paquets : ${missing[*]} ?" || {
    log_warn "Installation ignorée : ${missing[*]}"
    return 0
  }
  run_safe_dnf "Installation DNF de ${missing[*]}" install "${missing[@]}"
}

flatpak_installed() {
  flatpak info --system "$1" >/dev/null 2>&1
}

ensure_flatpak_app() {
  local application_id="$1"

  if ! flatpak remotes --system --columns=name 2>/dev/null | grep -qx flathub; then
    confirm_action safe "Ajouter Flathub avec une portée système ?" || {
      die "Flathub est requis pour $application_id."
      return 1
    }
    run_cmd "Ajout du dépôt Flathub" flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  fi

  if flatpak_installed "$application_id"; then
    log_ok "Flatpak déjà installé : $application_id"
    return 0
  fi

  if ! flatpak remote-info --system flathub "$application_id" >/dev/null 2>&1; then
    if is_true "$DRY_RUN"; then
      log_warn "[dry-run] $application_id sera revérifié après l'ajout de Flathub."
    else
      die "Application Flatpak introuvable sur Flathub : $application_id"
      return 1
    fi
  fi

  confirm_action safe "Installer le Flatpak $application_id ?" || {
    log_warn "Installation Flatpak ignorée : $application_id"
    return 0
  }
  local -a flatpak_command=(flatpak install)
  if is_true "$AUTO_CONFIRM_SAFE_ACTIONS" || is_true "$AUTO_CONFIRM_ALL_ACTIONS"; then
    flatpak_command+=(--assumeyes)
  fi
  flatpak_command+=(--system flathub "$application_id")
  run_cmd "Installation Flatpak de $application_id" "${flatpak_command[@]}"
}

validate_kernel_path() {
  local path="$1"
  [[ -n "$path" && "$path" == /boot/vmlinuz-* && -f "$path" && ! -L "$path" ]]
}

list_kernel_paths() {
  # Selon les permissions de /boot/grub2/grubenv, grubby peut nécessiter sudo
  # même pour une lecture. Le repli sur les fichiers réguliers de /boot garde
  # donc les simulations non privilégiées et strictement non modificatrices.
  local grubby_output
  grubby_output="$(grubby --info=ALL 2>/dev/null || true)"
  if [[ -n "$grubby_output" ]]; then
    awk -F= '$1 == "kernel" {gsub(/"/, "", $2); print $2}' <<<"$grubby_output"
    return
  fi

  local kernel_path
  for kernel_path in /boot/vmlinuz-*; do
    [[ -f "$kernel_path" && ! -L "$kernel_path" ]] && printf '%s\n' "$kernel_path"
  done
}

latest_fedora_kernel() {
  list_kernel_paths |
    awk '$0 ~ /^\/boot\/vmlinuz-/ && tolower($0) !~ /cachy|rescue/ {print}' |
    sort -V |
    tail -n 1
}

latest_cachy_kernel() {
  list_kernel_paths |
    awk '$0 ~ /^\/boot\/vmlinuz-/ && tolower($0) ~ /cachy/ {print}' |
    sort -V |
    tail -n 1
}

record_installed_version() {
  local key="$1"
  shift
  local output
  output="$("$@" 2>>"$LOG_FILE" | head -n 1 || true)"
  [[ -n "$output" ]] && state_set "$key" "$output"
  log_info "Version détectée pour $key : ${output:-inconnue}"
}

request_manual_reboot() {
  local checkpoint="$1"
  local reason="$2"

  state_set resume_required "$checkpoint"

  # Fedora Workstation masque normalement GRUB après un démarrage réussi.
  # Demander son affichage pour le prochain démarrage uniquement, sans changer
  # durablement l'expérience de démarrage de l'utilisateur.
  if command -v grub2-editenv >/dev/null 2>&1; then
    if ! run_cmd "Affichage de GRUB au prochain démarrage" sudo grub2-editenv - set menu_show_once=1; then
      log_warn "Impossible de programmer l'affichage unique de GRUB."
    fi
  else
    log_warn "grub2-editenv est absent : GRUB ne peut pas être affiché automatiquement."
  fi

  log_step "ACTION UTILISATEUR REQUISE — REDÉMARRAGE MANUEL"
  log_warn "$reason"
  log_warn "1. Redémarrez manuellement la machine."
  log_warn "2. Dans GRUB, sélectionnez le noyau CachyOS."
  log_warn "   Si le menu reste masqué, maintenez Maj gauche ou tapotez F8 pendant le démarrage."
  log_warn "3. Une fois connecté, relancez : ./fedora-setup.sh --resume"

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Le script continuerait après un redémarrage manuel."
    return 0
  fi

  exit 0
}

request_configured_reboot() {
  local checkpoint="$1"
  local reason="$2"

  state_set resume_required "$checkpoint"
  log_warn "$reason"

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Un redémarrage serait proposé."
    return 0
  fi

  if is_true "$AUTO_REBOOT"; then
    log_warn "AUTO_REBOOT=true : redémarrage dans 10 secondes. Ctrl-C pour annuler."
    sleep 10
    run_cmd "Redémarrage du système" sudo systemctl reboot
    exit 0
  fi

  if is_true "$AUTO_CONFIRM_ALL_ACTIONS"; then
    log_warn "AUTO_REBOOT=false : le redémarrage reste différé malgré le mode entièrement automatique."
    exit 0
  fi

  if confirm_action sensitive "Redémarrer maintenant ?"; then
    run_cmd "Redémarrage du système" sudo systemctl reboot
    exit 0
  fi

  log_warn "Redémarrage différé. Relancez ensuite avec --resume."
  exit 0
}

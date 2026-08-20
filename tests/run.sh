#!/usr/bin/env bash

# Tests sans privilèges : aucune commande DNF, Flatpak, sudo ou système n'est
# exécutée. Ils couvrent le parseur et les contrats statiques essentiels.

set -Eeuo pipefail
IFS=$'\n\t'

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd -- "$TEST_DIR/.." && pwd -P)"
readonly TEST_TMP="$(mktemp -d /tmp/fedora-setup-tests.XXXXXX)"

cleanup() {
  case "$TEST_TMP" in
    /tmp/fedora-setup-tests.*)
      [[ -d "$TEST_TMP" && ! -L "$TEST_TMP" ]] && rm -rf -- "$TEST_TMP"
      ;;
  esac
}
trap cleanup EXIT

# shellcheck source=../lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=../lib/config.sh
source "$PROJECT_DIR/lib/config.sh"

passed=0

ok() {
  printf 'ok - %s\n' "$1"
  ((passed += 1))
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_fails() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$description"
  fi
  ok "$description"
}

test_current_config() {
  set_config_defaults
  parse_config_file "$PROJECT_DIR/config.ini"
  [[ "$CONFIG_VERSION" == "1" ]] || fail "CONFIG_VERSION"
  [[ "$INSTALL_CLAMUI" == "true" ]] || fail "INSTALL_CLAMUI"
  [[ "$INSTALL_CACHYOS_ADDONS" == "true" ]] || fail "INSTALL_CACHYOS_ADDONS"
  [[ "$AUTO_CONFIRM_ALL_ACTIONS" == "true" ]] || fail "AUTO_CONFIRM_ALL_ACTIONS"
  [[ "$NVIDIA_DRIVER" == "auto" ]] || fail "NVIDIA_DRIVER"
  ok "config.ini est accepté et ses valeurs importantes sont chargées"
}

test_invalid_configs() {
  printf 'CONFIG_VERSION=1\nUNKNOWN_KEY=true\n' >"$TEST_TMP/unknown.ini"
  set_config_defaults
  assert_fails "une clé inconnue est refusée" parse_config_file "$TEST_TMP/unknown.ini"

  printf 'CONFIG_VERSION=1\nINSTALL_BRAVE=true\nINSTALL_BRAVE=false\n' >"$TEST_TMP/duplicate.ini"
  set_config_defaults
  assert_fails "une clé dupliquée est refusée" parse_config_file "$TEST_TMP/duplicate.ini"

  printf 'CONFIG_VERSION=1\nINSTALL_BRAVE=yes\n' >"$TEST_TMP/boolean.ini"
  set_config_defaults
  assert_fails "un booléen non canonique est refusé" parse_config_file "$TEST_TMP/boolean.ini"

  printf 'CONFIG_VERSION=2\n' >"$TEST_TMP/version.ini"
  set_config_defaults
  assert_fails "une version de schéma inconnue est refusée" parse_config_file "$TEST_TMP/version.ini"
}

test_entrypoints() {
  "$PROJECT_DIR/fedora-setup.sh" --help >/dev/null
  "$PROJECT_DIR/fedora-setup.sh" --validate-config --config "$PROJECT_DIR/config.ini" >/dev/null
  "$PROJECT_DIR/scripts/uninstall-cachyos.sh" --help >/dev/null
  ok "les points d'entrée et la validation autonome répondent"
}

test_shell_syntax() {
  local file
  while IFS= read -r file; do
    bash -n "$file"
  done < <(find "$PROJECT_DIR" -type f -name '*.sh' -print)
  ok "la syntaxe Bash de tous les scripts est valide"
}

test_static_guards() {
  local -a source_paths=("$PROJECT_DIR/fedora-setup.sh" "$PROJECT_DIR/lib" "$PROJECT_DIR/scripts")
  if grep -R -E 'source[[:space:]]+.*config\.ini|eval[[:space:]]' "${source_paths[@]}" >/dev/null; then
    fail "config.ini ne doit jamais être exécuté"
  fi
  if grep -R -n -F '+    ' "${source_paths[@]}" >/dev/null; then
    fail "aucun artefact de continuation de patch ne doit subsister"
  fi
  grep -Fq 'akmods --force --rebuild --kernels "$target_kernel_version"' "$PROJECT_DIR/lib/tasks.sh" ||
    fail "akmods doit compiler pour le noyau du prochain démarrage"
  grep -Fq 'modinfo -k "$target_kernel_version" -F version nvidia' "$PROJECT_DIR/lib/tasks.sh" ||
    fail "modinfo doit vérifier le noyau ciblé et non le noyau courant"
  if grep -Fq 'rpm -qf "$cachy_kernel"' "$PROJECT_DIR/lib/cachyos.sh" ||
    grep -Fq 'rpm -qf "$kernel_file"' "$PROJECT_DIR/lib/cachyos.sh"; then
    fail "/boot/vmlinuz CachyOS ne doit pas être supposé appartenir directement au RPM"
  fi
  grep -Fq 'validate_cachyos_kernel_package "$cachy_kernel"' "$PROJECT_DIR/lib/cachyos.sh" ||
    fail "le noyau CachyOS doit être validé depuis sa copie RPM canonique"
  grep -Fq 'ACTION UTILISATEUR REQUISE — REDÉMARRAGE MANUEL' "$PROJECT_DIR/lib/common.sh" ||
    fail "un redémarrage manuel doit être annoncé explicitement"
  grep -Fq 'grub2-editenv - set menu_show_once=1' "$PROJECT_DIR/lib/common.sh" ||
    fail "GRUB doit être affiché une fois avant le test manuel CachyOS"
  if grep -Fq "lsmod | grep -q '^nvidia'" "$PROJECT_DIR/lib/cachyos.sh"; then
    fail "la validation NVIDIA ne doit pas utiliser grep -q dans un pipeline pipefail"
  fi
  grep -Fq "grep -q '^nvidia ' /proc/modules" "$PROJECT_DIR/lib/cachyos.sh" ||
    fail "le chargement NVIDIA doit être vérifié directement dans /proc/modules"
  ok "les garde-fous statiques principaux sont présents"
}

test_safe_dnf_confirmation_mode() {
  local captured_command=""
  run_cmd() {
    captured_command="$(render_command "$@")"
  }

  AUTO_CONFIRM_ALL_ACTIONS=false
  AUTO_CONFIRM_SAFE_ACTIONS=true
  run_safe_dnf "Test DNF automatique" install exemple
  [[ "$captured_command" == *"sudo dnf --assumeyes install exemple"* ]] ||
    fail "AUTO_CONFIRM_SAFE_ACTIONS=true doit automatiser DNF"

  AUTO_CONFIRM_SAFE_ACTIONS=false
  run_safe_dnf "Test DNF interactif" install exemple
  [[ "$captured_command" == *"sudo dnf install exemple"* ]] ||
    fail "AUTO_CONFIRM_SAFE_ACTIONS=false doit laisser DNF interactif"

  ok "le mode de confirmation est transmis correctement à DNF"
}

test_full_automatic_dnf_mode() {
  local captured_command=""
  run_cmd() {
    captured_command="$(render_command "$@")"
  }

  AUTO_CONFIRM_SAFE_ACTIONS=false
  AUTO_CONFIRM_ALL_ACTIONS=true
  run_sensitive_dnf "Test DNF sensible automatique" copr enable exemple/projet
  [[ "$captured_command" == *"sudo dnf --assumeyes copr enable exemple/projet"* ]] ||
    fail "le mode complet doit automatiser les transactions DNF sensibles"

  AUTO_CONFIRM_ALL_ACTIONS=false
  run_sensitive_dnf "Test DNF sensible interactif" copr enable exemple/projet
  [[ "$captured_command" == *"sudo dnf copr enable exemple/projet"* ]] ||
    fail "sans mode complet, une transaction DNF sensible doit rester interactive"

  ok "le mode entièrement automatique est transmis aux transactions sensibles"
}

test_stateful_command_keeps_environment() {
  RUNTIME_TMP="$TEST_TMP"
  LOG_FILE="$TEST_TMP/stateful.log"
  DRY_RUN=false
  STATEFUL_TEST_VALUE="before"
  change_test_environment() {
    STATEFUL_TEST_VALUE="after"
    printf 'environnement modifié\n'
  }

  run_stateful_cmd "Test de commande avec état" change_test_environment >/dev/null
  [[ "$STATEFUL_TEST_VALUE" == "after" ]] ||
    fail "une commande avec état doit modifier le shell courant"
  ok "les commandes NVM conservent leurs changements d'environnement"
}

test_current_config
test_invalid_configs
test_entrypoints
test_shell_syntax
test_static_guards
test_safe_dnf_confirmation_mode
test_full_automatic_dnf_mode
test_stateful_command_keeps_environment

printf '1..%d\n' "$passed"

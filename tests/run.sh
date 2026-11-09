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
# shellcheck source=../lib/tasks.sh
source "$PROJECT_DIR/lib/tasks.sh"
# shellcheck source=../lib/theme.sh
source "$PROJECT_DIR/lib/theme.sh"

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
  [[ "$INSTALL_ONLYOFFICE" == "true" ]] || fail "INSTALL_ONLYOFFICE"
  [[ "$INSTALL_CACHYOS_ADDONS" == "true" ]] || fail "INSTALL_CACHYOS_ADDONS"
  [[ "$AUTO_CONFIRM_ALL_ACTIONS" == "true" ]] || fail "AUTO_CONFIRM_ALL_ACTIONS"
  [[ "$NVIDIA_DRIVER" == "auto" ]] || fail "NVIDIA_DRIVER"
  [[ "$SUPPRESSION_MEDIA_WRITER" == "true" ]] || fail "SUPPRESSION_MEDIA_WRITER"
  [[ "$HIDE_GRUB_AFTER_CACHYOS" == "true" ]] || fail "HIDE_GRUB_AFTER_CACHYOS"
  [[ "$APPLY_THEME" == "true" ]] || fail "APPLY_THEME"
  [[ "$APPLY_GNOME_EXTENSIONS" == "true" ]] || fail "APPLY_GNOME_EXTENSIONS"
  [[ "$APPLY_ZSH_CONFIG" == "true" ]] || fail "APPLY_ZSH_CONFIG"
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
  "$PROJECT_DIR/scripts/restore-theme.sh" --help >/dev/null
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
  local -a source_paths=("$PROJECT_DIR/fedora-setup.sh" "$PROJECT_DIR/lib" "$PROJECT_DIR/scripts" "$PROJECT_DIR/theme")
  if grep -R -i -E 'INSTALL_BOTTLES|com\.usebottles\.bottles|install_bottles' \
    "${source_paths[@]}" "$PROJECT_DIR/config.ini" "$PROJECT_DIR/README.md" "$PROJECT_DIR/PLANS.md" >/dev/null; then
    fail "Bottles ne doit plus être proposé ni installé"
  fi
  grep -Fq 'run_if_enabled INSTALL_ONLYOFFICE apps.onlyoffice "ONLYOFFICE Desktop Editors" install_onlyoffice' \
    "$PROJECT_DIR/lib/tasks.sh" || fail "ONLYOFFICE doit être intégré à l'étape applications"
  grep -Fq 'validate_flatpak_if_enabled INSTALL_ONLYOFFICE org.onlyoffice.desktopeditors' \
    "$PROJECT_DIR/lib/tasks.sh" || fail "le Flatpak ONLYOFFICE doit être validé"
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
  grep -Fq 'grub2-editenv - set menu_auto_hide=1' "$PROJECT_DIR/lib/cachyos.sh" ||
    fail "GRUB doit pouvoir être remasqué après les tests CachyOS"
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

test_final_reboot_checkpoint_is_cleared() {
  STATE_VALUES_DIR="$TEST_TMP/reboot-values"
  mkdir -p "$STATE_VALUES_DIR"
  DRY_RUN=false
  LOG_FILE="$TEST_TMP/reboot.log"

  state_set resume_required final
  state_set reboot_recommended true
  state_set reboot_requested_boot_id 00000000-0000-0000-0000-000000000000
  reconcile_final_reboot_checkpoint false

  [[ -z "$(state_get resume_required)" ]] || fail "le checkpoint final doit être effacé après redémarrage"
  [[ "$(state_get reboot_recommended)" == "false" ]] || fail "la recommandation de redémarrage doit être acquittée"
  ok "le redémarrage final ne provoque pas de boucle"
}

test_preinstalled_cleanup_is_conditional() {
  set_config_defaults
  SUPPRESSION_MEDIA_WRITER=true
  INSTALL_MPV=true
  INSTALL_BRAVE=true
  DRY_RUN=false
  LOG_FILE="$TEST_TMP/cleanup.log"

  package_installed() {
    case "$1" in
      mediawriter | mpv | showtime | brave-browser | firefox) return 0 ;;
      *) return 1 ;;
    esac
  }
  rpm() {
    return 0
  }
  local -a dnf_calls=()
  run_sensitive_dnf() {
    dnf_calls+=("$(render_command "$@")")
  }

  remove_preinstalled_fedora_apps
  [[ "${dnf_calls[0]}" == *"remove firefox mediawriter showtime"* ]] ||
    fail "les remplacements installés doivent déclencher les suppressions conditionnelles"
  [[ "${dnf_calls[1]}" == *"autoremove"* ]] ||
    fail "dnf autoremove doit suivre les suppressions"
  ok "le nettoyage Fedora respecte la configuration et les remplacements"
}

test_theme_profiles_are_strict() {
  validate_theme_profiles >/dev/null

  local original_gsettings="$THEME_GSETTINGS_PROFILE"
  THEME_GSETTINGS_PROFILE="$TEST_TMP/unsafe-gsettings.conf"
  printf "org.gnome.shell.extensions.gsconnect.devices|certificate|'secret'|gsconnect@andyholmes.github.io\n" >"$THEME_GSETTINGS_PROFILE"
  assert_fails "les données GSConnect sensibles sont refusées" validate_theme_profiles

  printf "org.gnome.desktop.interface|font-name|'Inter 12'|\norg.gnome.desktop.interface|font-name|'Inter 11'|\n" >"$THEME_GSETTINGS_PROFILE"
  assert_fails "les réglages GNOME dupliqués sont refusés" validate_theme_profiles
  THEME_GSETTINGS_PROFILE="$original_gsettings"

  local original_extensions="$THEME_EXTENSIONS_PROFILE"
  THEME_EXTENSIONS_PROFILE="$TEST_TMP/unsafe-extensions.conf"
  printf 'bad uuid|Test|-|1|1|not-a-checksum|true\n' >"$THEME_EXTENSIONS_PROFILE"
  assert_fails "les UUID et checksums d'extension invalides sont refusés" validate_theme_profiles
  THEME_EXTENSIONS_PROFILE="$original_extensions"

  validate_theme_profiles >/dev/null || fail "les manifestes officiels doivent rester valides"
  theme_profile_contains_setting org.gnome.shell.extensions.blur-my-shell pipelines blur-my-shell@aunetx ||
    fail "le pipeline personnalisé Blur My Shell doit rester dans le profil"
  theme_profile_contains_setting org.gnome.shell.extensions.dash-to-dock show-apps-at-top dash-to-dock@micxgx.gmail.com ||
    fail "la disposition Dash to Dock doit rester dans le profil"
  ok "les profils theme officiels sont stricts et exempts de données privées"
}

test_theme_zsh_block_preserves_user_content() {
  local original_home="$HOME"
  local original_xdg_config_home="${XDG_CONFIG_HOME:-}"
  HOME="$TEST_TMP/home"
  XDG_CONFIG_HOME="$HOME/.config"
  RUNTIME_TMP="$TEST_TMP"
  LOG_FILE="$TEST_TMP/theme-zsh.log"
  DRY_RUN=false
  mkdir -p "$HOME/.oh-my-zsh"
  printf '%s\n' \
    'alias personnel="printf conserve"' \
    'source "$ZSH/oh-my-zsh.sh"' \
    '# >>> fedora-post-install zsh >>>' \
    'ancien contenu' \
    '# <<< fedora-post-install zsh <<<' >"$HOME/.zshrc"

  configure_theme_zsh >/dev/null
  configure_theme_zsh >/dev/null
  grep -Fq 'alias personnel="printf conserve"' "$HOME/.zshrc" || fail "le contenu Zsh personnel doit être conservé"
  [[ "$(grep -Fc '# >>> fedora-post-install theme zsh >>>' "$HOME/.zshrc")" == "1" ]] ||
    fail "un seul bloc Zsh géré doit être présent"
  ! grep -Fq 'ancien contenu' "$HOME/.zshrc" || fail "l'ancien bloc géré doit être remplacé"
  grep -Fq "$MANAGED_MARKER" "$(theme_managed_zsh_target)" || fail "le module Zsh installé doit être signé"
  zsh -n "$HOME/.zshrc" "$(theme_managed_zsh_target)" || fail "la configuration Zsh produite doit être valide"

  HOME="$original_home"
  if [[ -n "$original_xdg_config_home" ]]; then
    XDG_CONFIG_HOME="$original_xdg_config_home"
  else
    unset XDG_CONFIG_HOME
  fi
  ok "le bloc Zsh géré est idempotent et préserve le contenu utilisateur"
}

test_theme_value_comparison() {
  theme_values_equal "0.9" "0.90000000000000002" || fail "les flottants GVariant équivalents doivent être acceptés"
  assert_fails "deux valeurs GVariant différentes sont refusées" theme_values_equal "true" "false"
  ok "la relecture GSettings tolère uniquement la normalisation numérique"
}

test_extension_validation_does_not_require_shell_cache() {
  local original_home="$HOME"
  HOME="$TEST_TMP/extension-home"
  local uuid="test-extension@example.com"
  local extension_dir="$HOME/.local/share/gnome-shell/extensions/$uuid"
  mkdir -p "$extension_dir"
  printf '%s\n' \
    '{' \
    '  "uuid": "test-extension@example.com",' \
    '  "version": 72,' \
    '  "shell-version": ["51"]' \
    '}' >"$extension_dir/metadata.json"

  gnome-shell() { printf 'GNOME Shell 51.1\n'; }
  theme_installed_extension_is_compatible "$uuid" 72 ||
    fail "la validation doit lire metadata.json sans dépendre du cache GNOME Shell"
  assert_fails "une version utilisateur différente du manifeste est refusée" \
    theme_installed_extension_is_compatible "$uuid" 71
  HOME="$original_home"
  unset -f gnome-shell
  ok "les extensions fraîchement installées sont validées directement sur disque"
}

test_legacy_dark_mode_fallback() {
  local original_profile="$THEME_GSETTINGS_PROFILE"
  THEME_GSETTINGS_PROFILE="$TEST_TMP/legacy-dark.conf"
  printf '%s\n' \
    "org.gnome.desktop.interface|color-scheme|'prefer-dark'|" \
    "org.gnome.desktop.interface|gtk-theme|'Adwaita'|" >"$THEME_GSETTINGS_PROFILE"
  STATE_VALUES_DIR="$TEST_TMP/theme-values"
  mkdir -p "$STATE_VALUES_DIR"
  DRY_RUN=false
  local applied_target=""

  theme_schema_has_key() {
    [[ "$2" != "color-scheme" ]]
  }
  theme_gsettings() {
    local uuid="$1"
    shift
    case "$1" in
      writable) printf 'true\n' ;;
      get) printf "'Adwaita'\n" ;;
      set) applied_target="${4}" ;;
    esac
  }
  run_cmd() {
    local description="$1"
    shift
    "$@"
  }

  apply_theme_gsettings >/dev/null
  [[ "$applied_target" == "'Adwaita-dark'" ]] || fail "Adwaita-dark doit remplacer color-scheme lorsqu'il est absent"
  [[ "$(state_get theme_legacy_dark)" == "true" ]] || fail "le repli sombre doit être enregistré pour la validation"
  THEME_GSETTINGS_PROFILE="$original_profile"
  ok "le mode sombre possède un repli compatible quand color-scheme est absent"
}

test_theme_validation_retries_without_blocking() {
  local original_profile="$THEME_GSETTINGS_PROFILE"
  THEME_GSETTINGS_PROFILE="$TEST_TMP/theme-retry.conf"
  printf '%s\n' 'org.gnome.desktop.interface|enable-hot-corners|false|' >"$THEME_GSETTINGS_PROFILE"
  STATE_VALUES_DIR="$TEST_TMP/theme-retry-values"
  mkdir -p "$STATE_VALUES_DIR"
  DRY_RUN=false
  APPLY_THEME=true
  APPLY_ZSH_CONFIG=false
  APPLY_GNOME_EXTENSIONS=false
  local current=true set_calls=0

  theme_schema_has_key() {
    return 0
  }
  theme_gsettings() {
    local uuid="$1"
    shift
    case "$1" in
      writable) printf 'true\n' ;;
      get) printf '%s\n' "$current" ;;
      set)
        current="$4"
        ((set_calls += 1))
        ;;
    esac
  }
  run_cmd() {
    local description="$1"
    shift
    "$@"
  }

  validate_theme_setting_with_retry org.gnome.desktop.interface enable-hot-corners false "" >/dev/null ||
    fail "la validation doit retenter un réglage GNOME divergent"
  [[ "$current" == "false" && "$set_calls" == "1" ]] ||
    fail "la seconde tentative doit appliquer la valeur cible"

  current=true
  theme_gsettings() {
    local uuid="$1"
    shift
    case "$1" in
      writable) printf 'true\n' ;;
      get) printf '%s\n' "$current" ;;
      set) ((set_calls += 1)) ;;
    esac
  }
  validate_theme_result >/dev/null || fail "un réglage GNOME rétabli par la session ne doit pas bloquer le script"
  [[ "$(state_get theme_validation_failures)" == *"enable-hot-corners"* ]] ||
    fail "le réglage non persistant doit rester signalé dans l'état"

  THEME_GSETTINGS_PROFILE="$original_profile"
  ok "la validation GNOME retente les valeurs sans bloquer sur une préférence non persistante"
}

test_extension_activation_queue_is_recognized() {
  gnome-extensions() {
    return 1
  }
  gsettings() {
    printf "%s\n" "['tiling-assistant@leleat-on-github']"
  }

  theme_extension_is_enabled_or_queued tiling-assistant@leleat-on-github ||
    fail "une extension programmée pour la prochaine connexion doit être reconnue"
  ok "l'activation différée de Tiling Assistant est reconnue"
}

test_fedora_identity() (
  validate_system_identity fedora 45 workstation x86_64 false || fail "Fedora 45 doit être acceptée"
  assert_fails "Fedora 44 est refusée" validate_system_identity fedora 44 workstation x86_64 false
  assert_fails "Atomic est refusé même avec une variante Workstation" validate_system_identity fedora 45 workstation x86_64 true
  assert_fails "aarch64 est refusé" validate_system_identity fedora 45 workstation aarch64 false
  assert_fails "KDE est refusé" validate_system_identity fedora 45 kde x86_64 false
  assert_fails "une autre distribution est refusée" validate_system_identity other 45 workstation x86_64 false
)

test_fedora_state_migration() (
  STATE_ROOT="$TEST_TMP/migration"
  STATE_STEPS_DIR="$STATE_ROOT/steps"
  STATE_VALUES_DIR="$STATE_ROOT/values"
  LOG_FILE="$TEST_TMP/migration.log"
  mkdir -p "$STATE_STEPS_DIR" "$STATE_VALUES_DIR" "$STATE_ROOT/theme/backups/ancien"
  DRY_RUN=false
  migrate_fedora_checkpoints >/dev/null
  [[ "$(state_get fedora_version)" == 45 && ! -d "$STATE_ROOT/migrations" ]] || fail "état neuf"
  rm "$STATE_VALUES_DIR/fedora_version"
  for step in prepare.upgrade repositories.rpmfusion desktop.gnome apps.pinta cleanup.preinstalled theme.backup development.node apps.brave cachyos.default-hook; do
    state_mark_step "$step"
  done
  state_set theme_backup_dir "$STATE_ROOT/theme/backups/ancien"
  state_set cachyos_complete true
  state_set resume_required final
  DRY_RUN=true
  migrate_fedora_checkpoints >/dev/null
  [[ -f "$STATE_STEPS_DIR/prepare.upgrade" && ! -d "$STATE_ROOT/migrations" && -z "$(state_get fedora_version)" ]] || fail "simulation modifie les checkpoints"
  ! state_step_done prepare.upgrade || fail "simulation doit montrer les étapes à rejouer"
  state_step_done apps.brave || fail "simulation conserve les applications"
  DRY_RUN=false
  migrate_fedora_checkpoints >/dev/null
  [[ "$(state_get fedora_version)" == 45 ]] || fail "version migrée"
  for step in prepare.upgrade repositories.rpmfusion desktop.gnome apps.pinta cleanup.preinstalled theme.backup; do
    ! state_step_done "$step" || fail "checkpoint hérité conservé : $step"
  done
  for step in development.node apps.brave cachyos.default-hook; do
    state_step_done "$step" || fail "checkpoint indépendant perdu : $step"
  done
  [[ "$(state_get resume_required)" == final && -d "$(state_get theme_backup_dir)" ]] || fail "valeurs de restauration perdues"
  local -a backups=("$STATE_ROOT"/migrations/fedora-45.*)
  [[ ${#backups[@]} == 1 && -f "${backups[0]}/steps/theme.backup" && -f "${backups[0]}/values/cachyos_complete" ]] || fail "sauvegarde de migration"
  state_mark_step prepare.upgrade
  migrate_fedora_checkpoints >/dev/null
  state_step_done prepare.upgrade || fail "migration répétée doit être sans effet"
)

test_fedora_migration_guards() (
  STATE_ROOT="$TEST_TMP/migration-guards"
  STATE_STEPS_DIR="$STATE_ROOT/steps"
  STATE_VALUES_DIR="$STATE_ROOT/values"
  LOG_FILE="$TEST_TMP/migration-guards.log"
  mkdir -p "$STATE_STEPS_DIR" "$STATE_VALUES_DIR"
  DRY_RUN=false
  state_set fedora_version 44
  state_mark_step prepare.upgrade
  state_set resume_required cachyos-kernel
  assert_fails "une transition CachyOS héritée bloque la migration" migrate_fedora_checkpoints
  [[ "$(state_get fedora_version)" == 44 && -f "$STATE_STEPS_DIR/prepare.upgrade" && ! -d "$STATE_ROOT/migrations" ]] || fail "transition modifiée"
  state_set resume_required uninstall-cachyos-fedora-boot
  assert_fails "une désinstallation CachyOS en attente est préservée" migrate_fedora_checkpoints
  state_set resume_required ""
  state_mark_step cachyos.kernel-installed
  assert_fails "une installation CachyOS incomplète sans marqueur bloque aussi" migrate_fedora_checkpoints
  state_set cachyos_complete true
  ln -s "$STATE_STEPS_DIR/prepare.upgrade" "$STATE_STEPS_DIR/theme.gnome"
  assert_fails "un checkpoint symbolique n'est pas effacé" migrate_fedora_checkpoints
  rm "$STATE_STEPS_DIR/theme.gnome"
  migrate_fedora_checkpoints >/dev/null
  [[ "$(state_get fedora_version)" == 45 ]] || fail "migration explicite 44 vers 45"
)

test_repository_detection() (
  LOG_FILE="$TEST_TMP/repositories.log"
  local mutations=0 output="" broken=false
  dnf() {
    [[ "$*" == "--quiet"$'\n'"repo"$'\n'"list"$'\n'"--all" ]] || fail "lecture DNF5 attendue"
    [[ "$broken" != true ]] || return 1
    printf '%s\n' "$output"
  }
  run_cmd() { ((mutations += 1)); }
  install_managed_content() { ((mutations += 1)); }
  for location in /usr/share/dnf5/repos.d /etc/yum.repos.d; do
    output="brave-browser Brave enabled ($location)"
    ensure_rpm_repository brave-browser https://example.org/brave.repo >/dev/null
    output="docker-ce-stable Docker disabled ($location)"
    ensure_rpm_repository docker-ce-stable https://example.org/docker.repo >/dev/null
    output="code VSCode enabled ($location)"
    ensure_rpm_repository code "" contenu >/dev/null
  done
  [[ "$mutations" == 0 ]] || fail "un dépôt existant ne doit pas être ajouté en double"
  output="code-insiders Code enabled"
  ensure_rpm_repository code "" contenu >/dev/null
  [[ "$mutations" == 1 ]] || fail "identifiant exact attendu"
  output=""
  ensure_rpm_repository brave-browser https://example.org/brave.repo >/dev/null
  [[ "$mutations" == 2 ]] || fail "dépôt absent non ajouté"
  broken=true
  assert_fails "une erreur DNF5 ne déclenche pas un ajout" ensure_rpm_repository code "" contenu
  [[ "$mutations" == 2 ]] || fail "écriture après erreur DNF5"
)

test_extension_archive_compatibility() (
  RUNTIME_TMP="$TEST_TMP"
  LOG_FILE="$TEST_TMP/archive-validation.log"
  DRY_RUN=false
  local archive="$TEST_TMP/extension.zip"
  make_archive() {
    python3 - "$archive" "$1" <<'PY'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as archive:
    archive.writestr('metadata.json', json.dumps({'uuid': 'test@example.com', 'version': 1, 'shell-version': [sys.argv[2]]}))
PY
  }
  make_archive 51
  theme_validate_extension_archive "$archive" test@example.com 1 51 || fail "archive GNOME 51"
  assert_fails "un UUID inattendu est refusé" theme_validate_extension_archive "$archive" autre@example.com 1 51
  assert_fails "une version inattendue est refusée" theme_validate_extension_archive "$archive" test@example.com 2 51
  make_archive 50
  assert_fails "une archive GNOME 50 est refusée" theme_validate_extension_archive "$archive" test@example.com 1 51
  printf 'archive altérée' >"$archive"
  assert_fails "une archive altérée est refusée" theme_validate_extension_archive "$archive" test@example.com 1 51
  package_available() { return 1; }
  package_installed() { return 1; }
  theme_installed_extension_is_compatible() { return 1; }
  assert_fails "une extension sans publication compatible reste réessayable" install_one_theme_extension test@example.com Test - 0 0 - true
  make_archive 51
  confirm_action() { return 0; }
  run_cmd() { shift; "$@"; }
  curl() { cp "$archive" "${@: -1}"; }
  gnome-extensions() { fail "une archive altérée ne doit pas être installée"; }
  local wrong_checksum
  printf -v wrong_checksum '%064d' 0
  assert_fails "un SHA-256 incorrect bloque l'installation" install_one_theme_extension test@example.com Test - 1 1 "$wrong_checksum" true
)

test_gnome_target() (
  APPLY_THEME=true
  APPLY_GNOME_EXTENSIONS=false
  APPLY_ZSH_CONFIG=false
  local shell_version=51.1
  require_command() { return 0; }
  ensure_dnf_packages() { return 0; }
  gnome-shell() { printf 'GNOME Shell %s\n' "$shell_version"; }
  theme_preflight >/dev/null || fail "GNOME 51 doit être accepté"
  shell_version=50.5
  assert_fails "le profil refuse GNOME 50" theme_preflight
)

test_rpmfusion_bootstrap_signatures() (
  LOG_FILE="$TEST_TMP/rpmfusion.log"
  DRY_RUN=true
  local calls=""
  package_installed() { return 1; }
  rpm() { printf '45\n'; }
  ensure_dnf_packages() { calls+="package:$1;"; }
  run_cmd() { calls+="$(render_command "$@");"; }
  run_safe_dnf() { calls+="$(render_command "$@");"; }
  enable_rpmfusion >/dev/null
  [[ "$calls" == package:distribution-gpg-keys\;* ]] || fail "clés Fedora avant RPM Fusion"
  [[ "$calls" == *"rpm --import /usr/share/distribution-gpg-keys/rpmfusion/RPM-GPG-KEY-rpmfusion-free-fedora-45"* ]] || fail "clé Free"
  [[ "$calls" == *"rpm --import /usr/share/distribution-gpg-keys/rpmfusion/RPM-GPG-KEY-rpmfusion-nonfree-fedora-45"* ]] || fail "clé Nonfree"
  [[ "$calls" == *"--setopt=localpkg_gpgcheck=1 install"* ]] || fail "signature des RPM distants"
  calls=""
  run_cmd() { return 1; }
  assert_fails "un échec d'import de clé bloque RPM Fusion" enable_rpmfusion
  [[ "$calls" != *"localpkg_gpgcheck"* ]] || fail "transaction après échec d'import"
)

test_pinta_source() (
  local installed=false source=""
  package_installed() { [[ "$1" == pinta && "$installed" == true ]]; }
  ensure_flatpak_app() { source="$1"; }
  install_pinta >/dev/null
  [[ "$source" == com.github.PintaProject.Pinta ]] || fail "Pinta doit utiliser Flathub"
  source=""
  installed=true
  install_pinta >/dev/null
  [[ -z "$source" ]] || fail "le RPM Pinta existant doit être conservé"
)

for isolated_test in test_fedora_identity test_fedora_state_migration test_fedora_migration_guards test_repository_detection test_extension_archive_compatibility test_gnome_target test_rpmfusion_bootstrap_signatures test_pinta_source; do
  "$isolated_test" >"$TEST_TMP/$isolated_test.log"
  ok "$isolated_test"
done
test_current_config
test_invalid_configs
test_entrypoints
test_shell_syntax
test_static_guards
test_safe_dnf_confirmation_mode
test_full_automatic_dnf_mode
test_stateful_command_keeps_environment
test_final_reboot_checkpoint_is_cleared
test_preinstalled_cleanup_is_conditional
test_theme_profiles_are_strict
test_theme_zsh_block_preserves_user_content
test_theme_value_comparison
test_extension_validation_does_not_require_shell_cache
test_legacy_dark_mode_fallback
test_theme_validation_retries_without_blocking
test_extension_activation_queue_is_recognized

printf '1..%d\n' "$passed"

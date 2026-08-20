#!/usr/bin/env bash

# Restaure la dernière sauvegarde créée par l'étape theme. Le script ne touche
# qu'aux clés, UUID et fichiers explicitement gérés par Fedora Setup.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=../lib/theme.sh
source "$SCRIPT_DIR/lib/theme.sh"

BACKUP_PATH=""

usage() {
  cat <<'EOF'
Usage :
  ./scripts/restore-theme.sh [--dry-run] [--backup CHEMIN] [--help]

Sans --backup, la dernière sauvegarde enregistrée par fedora-setup.sh est utilisée.
Le script restaure GSettings, l'état des extensions et les fichiers Zsh gérés.
EOF
}

parse_restore_arguments() {
  while (($# > 0)); do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --backup)
        (($# >= 2)) || {
          die "--backup attend un chemin."
          return 1
        }
        BACKUP_PATH="$2"
        shift 2
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        die "Option inconnue : $1"
        return 1
        ;;
    esac
  done
}

resolve_theme_backup() {
  local requested="$1"
  [[ -n "$requested" ]] || requested="$(state_get theme_backup_dir)"
  [[ -n "$requested" && "$requested" != "simulation" ]] || {
    die "Aucune sauvegarde theme n'est enregistrée."
    return 1
  }

  [[ ! -L "$requested" ]] || {
    die "Une sauvegarde theme ne peut pas être un lien symbolique."
    return 1
  }
  local backup_root="$STATE_ROOT/theme/backups"
  [[ -d "$backup_root" && ! -L "$backup_root" ]] || {
    die "Répertoire de sauvegarde theme introuvable."
    return 1
  }
  local resolved_root resolved_backup
  resolved_root="$(realpath -e -- "$backup_root")" || return 1
  resolved_backup="$(realpath -e -- "$requested")" || return 1
  [[ "$resolved_backup" == "$resolved_root/"* && -d "$resolved_backup" && ! -L "$resolved_backup" ]] || {
    die "Sauvegarde refusée hors du répertoire géré : $requested"
    return 1
  }
  printf '%s' "$resolved_backup"
}

restore_gsettings() {
  local backup_dir="$1"
  local data="$backup_dir/gsettings.tsv"
  [[ -f "$data" && ! -L "$data" ]] || {
    die "Sauvegarde GSettings invalide : $data"
    return 1
  }

  local schema key uuid encoded value
  while IFS=$'\t' read -r schema key uuid encoded; do
    [[ -n "$schema" && -n "$key" && -n "$encoded" ]] || {
      die "Ligne GSettings sauvegardée invalide."
      return 1
    }
    theme_profile_line_is_safe "$schema" "$key" "saved" "$uuid" || {
      die "Réglage sauvegardé invalide : $schema.$key"
      return 1
    }
    theme_profile_contains_setting "$schema" "$key" "$uuid" || {
      die "Réglage sauvegardé hors du profil courant : $schema.$key"
      return 1
    }
    value="$(printf '%s' "$encoded" | base64 --decode)"
    theme_schema_has_key "$schema" "$key" "$uuid" || {
      log_warn "Schéma absent pendant la restauration : $schema.$key"
      continue
    }
    run_cmd "Restauration de $schema.$key" theme_gsettings "$uuid" set "$schema" "$key" "$value"
  done <"$data"
}

restore_zsh_files() {
  local backup_dir="$1"
  local zshrc="$HOME/.zshrc"
  local managed_target
  managed_target="$(theme_managed_zsh_target)"

  local zshrc_status managed_status
  [[ -f "$backup_dir/zshrc.status" && ! -L "$backup_dir/zshrc.status" ]] || {
    die "État Zsh sauvegardé introuvable."
    return 1
  }
  [[ -f "$backup_dir/managed.status" && ! -L "$backup_dir/managed.status" ]] || {
    die "État du module Zsh sauvegardé introuvable."
    return 1
  }
  zshrc_status="$(<"$backup_dir/zshrc.status")"
  managed_status="$(<"$backup_dir/managed.status")"
  [[ "$zshrc_status" == "present" || "$zshrc_status" == "absent" || "$zshrc_status" == "skipped" ]] || {
    die "État Zsh sauvegardé invalide."
    return 1
  }
  [[ "$managed_status" == "present" || "$managed_status" == "absent" || "$managed_status" == "skipped" ]] || {
    die "État du module Zsh sauvegardé invalide."
    return 1
  }

  if [[ "$zshrc_status" == "present" ]]; then
    [[ -f "$backup_dir/zshrc" && ! -L "$backup_dir/zshrc" ]] || {
      die "Copie Zsh sauvegardée invalide."
      return 1
    }
    if is_true "$DRY_RUN"; then
      log_info "[dry-run] $zshrc serait restauré depuis la sauvegarde."
    else
      [[ ! -e "$zshrc" || (-f "$zshrc" && ! -L "$zshrc") ]] || {
        die "$zshrc n'est pas un fichier régulier."
        return 1
      }
      install -m 0600 "$backup_dir/zshrc" "$zshrc"
    fi
  elif [[ -f "$zshrc" && ! -L "$zshrc" ]]; then
    local stripped="$RUNTIME_TMP/zshrc-restored"
    awk '
      BEGIN {inside = 0}
      /^# >>> fedora-post-install theme zsh >>>$/ {inside = 1; next}
      /^# <<< fedora-post-install theme zsh <<</ {inside = 0; next}
      inside {next}
      {print}
    ' "$zshrc" >"$stripped"
    if is_true "$DRY_RUN"; then
      log_info "[dry-run] Le bloc theme serait retiré de $zshrc."
    elif grep -q '[^[:space:]]' "$stripped"; then
      chmod --reference="$zshrc" "$stripped"
      mv -f -- "$stripped" "$zshrc"
    else
      rm -f -- "$zshrc"
    fi
  fi

  if [[ "$managed_status" == "present" ]]; then
    [[ -f "$backup_dir/managed.zsh" && ! -L "$backup_dir/managed.zsh" ]] || {
      die "Module Zsh sauvegardé invalide."
      return 1
    }
    if is_true "$DRY_RUN"; then
      log_info "[dry-run] $managed_target serait restauré."
    else
      mkdir -p "$(dirname -- "$managed_target")"
      [[ ! -e "$managed_target" || (-f "$managed_target" && ! -L "$managed_target") ]] || {
        die "$managed_target n'est pas un fichier régulier."
        return 1
      }
      install -m 0644 "$backup_dir/managed.zsh" "$managed_target"
    fi
  elif [[ -e "$managed_target" || -L "$managed_target" ]]; then
    [[ -f "$managed_target" && ! -L "$managed_target" ]] || {
      die "$managed_target n'est pas un fichier régulier."
      return 1
    }
    grep -Fq "$MANAGED_MARKER" "$managed_target" || {
      die "Refus de supprimer un module Zsh non géré."
      return 1
    }
    if is_true "$DRY_RUN"; then
      log_info "[dry-run] Le module géré $managed_target serait supprimé."
    else
      rm -f -- "$managed_target"
    fi
  fi
}

restore_extension_states() {
  local backup_dir="$1"
  local extension_status
  [[ -f "$backup_dir/extensions.status" && ! -L "$backup_dir/extensions.status" ]] || {
    die "État d'extensions sauvegardé introuvable."
    return 1
  }
  extension_status="$(<"$backup_dir/extensions.status")"
  [[ "$extension_status" == "present" || "$extension_status" == "skipped" ]] || {
    die "État d'extensions sauvegardé invalide."
    return 1
  }
  if [[ "$extension_status" == "skipped" ]]; then
    log_info "Extensions non concernées par cette sauvegarde : restauration ignorée."
    return 0
  fi
  local installed_before="$backup_dir/extensions.installed"
  local enabled_before="$backup_dir/extensions.enabled"
  [[ -f "$installed_before" && ! -L "$installed_before" ]] || {
    die "Liste d'extensions sauvegardée invalide."
    return 1
  }
  [[ -f "$enabled_before" && ! -L "$enabled_before" ]] || {
    die "État d'extensions sauvegardé invalide."
    return 1
  }

  local raw uuid name package version version_tag checksum enable extra extension_dir expected_user_dir
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    [[ -z "$raw" || "$raw" == \#* ]] && continue
    IFS='|' read -r uuid name package version version_tag checksum enable extra <<<"$raw"
    gnome-extensions info "$uuid" >/dev/null 2>&1 || continue

    if grep -Fxq "$uuid" "$installed_before"; then
      if grep -Fxq "$uuid" "$enabled_before"; then
        run_cmd "Réactivation de $name" gnome-extensions enable "$uuid"
      else
        run_cmd "Désactivation de $name" gnome-extensions disable "$uuid"
      fi
      continue
    fi

    extension_dir="$(theme_extension_dir "$uuid" || true)"
    expected_user_dir="$HOME/.local/share/gnome-shell/extensions/$uuid"
    if [[ "$extension_dir" == "$expected_user_dir" && -d "$extension_dir" && ! -L "$extension_dir" ]] &&
      confirm_action sensitive "Désinstaller l'extension ajoutée par le profil : $name ?"; then
      run_cmd "Désinstallation de $name" gnome-extensions uninstall "$uuid"
    else
      run_cmd "Désactivation de l'extension ajoutée $name" gnome-extensions disable "$uuid"
      log_warn "$name reste installé ; aucun paquet système n'est supprimé automatiquement."
    fi
  done <"$THEME_EXTENSIONS_PROFILE"
}

clear_theme_checkpoints() {
  local step path
  for step in theme.preflight theme.backup theme.extensions theme.gnome theme.zsh theme.validate; do
    state_key_is_valid "$step" || {
      die "Checkpoint theme interne invalide : $step"
      return 1
    }
    path="$STATE_STEPS_DIR/$step"
    [[ ! -e "$path" || (-f "$path" && ! -L "$path") ]] || {
      die "Checkpoint theme non régulier : $path"
      return 1
    }
    if is_true "$DRY_RUN"; then
      log_info "[dry-run] Le checkpoint $step serait effacé."
    else
      rm -f -- "$path"
    fi
  done
  state_set theme_profile_signature ""
}

main() {
  parse_restore_arguments "$@"
  init_runtime restore-theme
  require_non_root
  require_command realpath
  require_command base64
  require_command gsettings
  require_command gnome-extensions
  validate_theme_profiles

  local backup_dir
  backup_dir="$(resolve_theme_backup "$BACKUP_PATH")"
  log_step "Restauration du profil GNOME/Zsh"
  log_info "Sauvegarde sélectionnée : $backup_dir"
  confirm_action sensitive "Restaurer le profil utilisateur précédent ?" || {
    die "Restauration annulée."
    return 1
  }

  restore_gsettings "$backup_dir"
  restore_extension_states "$backup_dir"
  restore_zsh_files "$backup_dir"
  clear_theme_checkpoints
  state_set logout_required true
  log_ok "Profil restauré. Déconnectez-vous puis reconnectez-vous pour recharger GNOME Shell."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

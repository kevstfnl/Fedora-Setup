#!/usr/bin/env bash

# Application défensive du profil GNOME/Zsh. Les fichiers theme/*.conf sont
# lus comme des données et ne sont jamais exécutés avec source ou eval.

THEME_MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
THEME_PROJECT_DIR="$(cd -- "$THEME_MODULE_DIR/.." && pwd -P)"
THEME_GSETTINGS_PROFILE="$THEME_PROJECT_DIR/theme/gsettings.conf"
THEME_EXTENSIONS_PROFILE="$THEME_PROJECT_DIR/theme/extensions.conf"
THEME_ZSH_SOURCE="$THEME_PROJECT_DIR/theme/zsh/managed.zsh"

theme_managed_zsh_target() {
  printf '%s/fedora-post-install/zsh/managed.zsh' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

theme_extension_dir() {
  local uuid="$1"
  local candidate
  for candidate in \
    "$HOME/.local/share/gnome-shell/extensions/$uuid" \
    "/usr/share/gnome-shell/extensions/$uuid"; do
    if [[ -d "$candidate" && ! -L "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

theme_gsettings() {
  local uuid="$1"
  shift
  local -a command=(gsettings)
  local extension_dir
  if [[ -n "$uuid" ]] && extension_dir="$(theme_extension_dir "$uuid")" &&
    [[ -d "$extension_dir/schemas" ]]; then
    command+=(--schemadir "$extension_dir/schemas")
  fi
  "${command[@]}" "$@"
}

theme_schema_has_key() {
  local schema="$1"
  local key="$2"
  local uuid="$3"
  theme_gsettings "$uuid" list-keys "$schema" 2>/dev/null | grep -Fxq "$key"
}

theme_profile_contains_setting() {
  local expected_schema="$1" expected_key="$2" expected_uuid="$3"
  local raw schema key value uuid extra
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    [[ -z "$raw" || "$raw" == \#* ]] && continue
    IFS='|' read -r schema key value uuid extra <<<"$raw"
    [[ "$schema" == "$expected_schema" && "$key" == "$expected_key" && "$uuid" == "$expected_uuid" ]] && return 0
  done <"$THEME_GSETTINGS_PROFILE"
  return 1
}

theme_profile_line_is_safe() {
  local schema="$1"
  local key="$2"
  local value="$3"
  local uuid="$4"

  [[ "$schema" =~ ^org\.gnome\.(desktop\.(interface|wm\.preferences)|mutter|shell\.extensions\.[a-zA-Z0-9.-]+)$ ]] || return 1
  [[ "$key" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  [[ -z "$uuid" || "$uuid" =~ ^[a-zA-Z0-9._@-]+$ ]] || return 1

  local joined="${schema}.${key}.${uuid}"
  [[ ! "$joined" =~ (gsconnect.*(device|certificate|address)|weather|location|touchpad|mouse|eDP-[0-9]) ]]
}

validate_theme_profiles() {
  local profile
  for profile in "$THEME_GSETTINGS_PROFILE" "$THEME_EXTENSIONS_PROFILE" "$THEME_ZSH_SOURCE"; do
    [[ -f "$profile" && ! -L "$profile" ]] || {
      die "Profil theme invalide ou introuvable : $profile"
      return 1
    }
  done

  local raw schema key value uuid extra line_number=0
  declare -A settings_seen=()
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    ((line_number += 1))
    raw="${raw%$'\r'}"
    [[ -z "$raw" || "$raw" == \#* ]] && continue
    IFS='|' read -r schema key value uuid extra <<<"$raw"
    [[ -z "${extra:-}" ]] || {
      die "$THEME_GSETTINGS_PROFILE:$line_number contient trop de champs."
      return 1
    }
    theme_profile_line_is_safe "$schema" "$key" "$value" "$uuid" || {
      die "$THEME_GSETTINGS_PROFILE:$line_number contient un réglage interdit ou invalide."
      return 1
    }
    [[ -z "${settings_seen[$schema.$key]:-}" ]] || {
      die "$THEME_GSETTINGS_PROFILE:$line_number duplique $schema.$key."
      return 1
    }
    settings_seen["$schema.$key"]=1
  done <"$THEME_GSETTINGS_PROFILE"

  local name package version version_tag checksum enable
  line_number=0
  declare -A extensions_seen=()
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    ((line_number += 1))
    raw="${raw%$'\r'}"
    [[ -z "$raw" || "$raw" == \#* ]] && continue
    IFS='|' read -r uuid name package version version_tag checksum enable extra <<<"$raw"
    [[ -z "${extra:-}" ]] || {
      die "$THEME_EXTENSIONS_PROFILE:$line_number contient trop de champs."
      return 1
    }
    [[ "$uuid" =~ ^[a-zA-Z0-9._@-]+$ && -n "$name" ]] || {
      die "$THEME_EXTENSIONS_PROFILE:$line_number contient une extension invalide."
      return 1
    }
    [[ "$package" == "-" || "$package" =~ ^[a-zA-Z0-9+._-]+$ ]] || {
      die "$THEME_EXTENSIONS_PROFILE:$line_number contient un paquet invalide."
      return 1
    }
    [[ "$version" =~ ^[0-9]+$ && "$version_tag" =~ ^[0-9]+$ ]] || {
      die "$THEME_EXTENSIONS_PROFILE:$line_number contient une version invalide."
      return 1
    }
    [[ "$enable" == "true" || "$enable" == "false" ]] || {
      die "$THEME_EXTENSIONS_PROFILE:$line_number contient un booléen invalide."
      return 1
    }
    if ((version_tag == 0)); then
      [[ "$version" == "0" && "$checksum" == "-" && "$package" != "-" ]] || {
        die "$THEME_EXTENSIONS_PROFILE:$line_number a une source incomplète."
        return 1
      }
    else
      [[ "$version" != "0" && "$checksum" =~ ^[a-f0-9]{64}$ ]] || {
        die "$THEME_EXTENSIONS_PROFILE:$line_number a une archive non vérifiable."
        return 1
      }
    fi
    [[ -z "${extensions_seen[$uuid]:-}" ]] || {
      die "$THEME_EXTENSIONS_PROFILE:$line_number duplique $uuid."
      return 1
    }
    extensions_seen["$uuid"]=1
  done <"$THEME_EXTENSIONS_PROFILE"

  log_ok "Profils GNOME, extensions et Zsh validés."
}

theme_preflight() {
  validate_theme_profiles

  if [[ "$APPLY_THEME" == "true" || "$APPLY_GNOME_EXTENSIONS" == "true" ]]; then
    local command_name
    for command_name in gsettings gnome-extensions gnome-shell base64; do
      require_command "$command_name"
    done
    local shell_major
    shell_major="$(gnome-shell --version | awk '{print $NF}' | cut -d. -f1)"
    [[ "$shell_major" == "50" ]] || {
      die "Le profil theme exige GNOME Shell 50 ; version détectée : ${shell_major:-inconnue}."
      return 1
    }
    if [[ "${XDG_CURRENT_DESKTOP:-}" != *GNOME* ]]; then
      log_warn "Session GNOME non confirmée par XDG_CURRENT_DESKTOP ; les extensions pourront nécessiter une reconnexion."
    fi
  fi

  if [[ "$APPLY_THEME" == "true" ]]; then
    ensure_dnf_packages papirus-icon-theme fontconfig
  fi
  if [[ "$APPLY_GNOME_EXTENSIONS" == "true" ]]; then
    ensure_dnf_packages unzip jq curl gnome-extensions-app
  fi
  if [[ "$APPLY_ZSH_CONFIG" == "true" ]]; then
    require_command zsh
    [[ -d "$HOME/.oh-my-zsh" && ! -L "$HOME/.oh-my-zsh" ]] || {
      die "Oh My Zsh est requis. Exécutez d'abord l'étape desktop."
      return 1
    }
  fi
}

backup_theme_state() {
  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Les réglages GNOME, extensions et fichiers Zsh concernés seraient sauvegardés."
    state_set theme_backup_dir "simulation"
    return 0
  fi

  local backup_root="$STATE_ROOT/theme/backups"
  mkdir -p -m 0700 "$backup_root"
  local backup_dir="$backup_root/$(date +%Y%m%dT%H%M%S)-$$"
  mkdir -m 0700 "$backup_dir"

  local raw schema key value uuid extra encoded
  : >"$backup_dir/gsettings.tsv"
  if [[ "$APPLY_THEME" == "true" ]]; then
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      raw="${raw%$'\r'}"
      [[ -z "$raw" || "$raw" == \#* ]] && continue
      IFS='|' read -r schema key value uuid extra <<<"$raw"
      if theme_schema_has_key "$schema" "$key" "$uuid"; then
        value="$(theme_gsettings "$uuid" get "$schema" "$key")"
        encoded="$(printf '%s' "$value" | base64 -w 0)"
        printf '%s\t%s\t%s\t%s\n' "$schema" "$key" "$uuid" "$encoded" >>"$backup_dir/gsettings.tsv"
      fi
    done <"$THEME_GSETTINGS_PROFILE"
  fi
  chmod 0600 "$backup_dir/gsettings.tsv"

  : >"$backup_dir/extensions.installed"
  : >"$backup_dir/extensions.enabled"
  if [[ "$APPLY_GNOME_EXTENSIONS" == "true" ]]; then
    gnome-extensions list >"$backup_dir/extensions.installed" 2>/dev/null || true
    gnome-extensions list --enabled >"$backup_dir/extensions.enabled" 2>/dev/null || true
    printf 'present\n' >"$backup_dir/extensions.status"
  else
    printf 'skipped\n' >"$backup_dir/extensions.status"
  fi
  chmod 0600 "$backup_dir/extensions.installed" "$backup_dir/extensions.enabled"

  local zshrc="$HOME/.zshrc"
  local managed_target
  managed_target="$(theme_managed_zsh_target)"
  if [[ "$APPLY_ZSH_CONFIG" != "true" ]]; then
    printf 'skipped\n' >"$backup_dir/zshrc.status"
    printf 'skipped\n' >"$backup_dir/managed.status"
  elif [[ -e "$zshrc" || -L "$zshrc" ]]; then
    [[ -f "$zshrc" && ! -L "$zshrc" ]] || {
      die "$zshrc doit être un fichier régulier."
      return 1
    }
    cp -p -- "$zshrc" "$backup_dir/zshrc"
    printf 'present\n' >"$backup_dir/zshrc.status"
  else
    printf 'absent\n' >"$backup_dir/zshrc.status"
  fi
  if [[ "$APPLY_ZSH_CONFIG" != "true" ]]; then
    :
  elif [[ -e "$managed_target" || -L "$managed_target" ]]; then
    [[ -f "$managed_target" && ! -L "$managed_target" ]] || {
      die "$managed_target doit être un fichier régulier."
      return 1
    }
    cp -p -- "$managed_target" "$backup_dir/managed.zsh"
    printf 'present\n' >"$backup_dir/managed.status"
  else
    printf 'absent\n' >"$backup_dir/managed.status"
  fi
  chmod 0600 "$backup_dir"/*.status

  printf 'profile_version=1\ncreated=%s\n' "$(date --iso-8601=seconds)" >"$backup_dir/metadata"
  chmod 0600 "$backup_dir/metadata"
  state_set theme_backup_dir "$backup_dir"
  log_ok "État du thème sauvegardé dans $backup_dir"
}

theme_validate_extension_archive() {
  local archive="$1"
  local uuid="$2"
  local expected_version="$3"
  local shell_major="$4"
  local metadata="$RUNTIME_TMP/metadata-${uuid//[^a-zA-Z0-9._-]/_}.json"

  unzip -p "$archive" metadata.json >"$metadata" || return 1
  [[ "$(jq -r '.uuid // empty' "$metadata")" == "$uuid" ]] || return 1
  [[ "$(jq -r '.version // empty' "$metadata")" == "$expected_version" ]] || return 1
  jq -e --arg shell "$shell_major" '."shell-version" | index($shell) != null' "$metadata" >/dev/null
}

theme_installed_extension_is_compatible() {
  local uuid="$1"
  local expected_version="$2"

  local extension_dir metadata shell_major actual_uuid actual_version
  extension_dir="$(theme_extension_dir "$uuid")" || return 1
  metadata="$extension_dir/metadata.json"
  [[ -f "$metadata" && ! -L "$metadata" ]] || return 1
  shell_major="$(gnome-shell --version | awk '{print $NF}' | cut -d. -f1)"
  actual_uuid="$(jq -r '.uuid // empty' "$metadata")"
  actual_version="$(jq -r '.version // 0' "$metadata")"
  [[ "$actual_uuid" == "$uuid" ]] || return 1
  jq -e --arg shell "$shell_major" '."shell-version" | index($shell) != null' "$metadata" >/dev/null || return 1

  # Les paquets Fedora suivent GNOME et peuvent porter une version différente.
  # Les extensions utilisateur téléchargées doivent correspondre au manifeste.
  if [[ "$extension_dir" == "$HOME/.local/share/gnome-shell/extensions/$uuid" && "$expected_version" != "0" ]]; then
    [[ "$actual_version" == "$expected_version" ]] || return 1
  fi
}

theme_enable_extension() {
  local uuid="$1"
  local name="$2"

  if gnome-extensions enable "$uuid" >>"$LOG_FILE" 2>&1; then
    log_ok "Extension activée : $name"
    return 0
  fi

  # Juste après une installation, GNOME Shell peut ne pas avoir encore
  # actualisé son cache. Enregistrer alors l'UUID pour la prochaine connexion.
  local enabled target
  enabled="$(gsettings get org.gnome.shell enabled-extensions)" || return 1
  if grep -Fq "'$uuid'" <<<"$enabled"; then
    log_ok "Extension déjà programmée pour la prochaine connexion : $name"
    return 0
  fi
  case "$enabled" in
    "[]" | "@as []") target="['$uuid']" ;;
    *']') target="${enabled%]}, '$uuid']" ;;
    *) return 1 ;;
  esac
  run_cmd "Activation différée de l'extension $name" gsettings set org.gnome.shell enabled-extensions "$target" || return 1
  log_warn "$name sera chargée après déconnexion/reconnexion de GNOME."
}

install_one_theme_extension() {
  local uuid="$1" name="$2" package="$3" version="$4" version_tag="$5" checksum="$6" enable="$7"

  if ! theme_installed_extension_is_compatible "$uuid" "$version" && [[ "$package" != "-" ]]; then
    if package_installed "$package" || package_available "$package"; then
      ensure_dnf_packages "$package" || return 1
    else
      log_warn "Paquet Fedora indisponible pour $name : $package ; utilisation de l'archive officielle."
    fi
  fi

  if ! theme_installed_extension_is_compatible "$uuid" "$version"; then
    ((version_tag > 0)) || {
      die "$name est absent et ne possède aucun repli officiel dans le manifeste."
      return 1
    }
    confirm_action safe "Installer l'extension GNOME $name $version ?" || {
      log_warn "Extension ignorée : $name"
      return 0
    }

    local archive="$RUNTIME_TMP/${uuid//[^a-zA-Z0-9._-]/_}.zip"
    local url="https://extensions.gnome.org/download-extension/${uuid}.shell-extension.zip?version_tag=${version_tag}"
    run_cmd "Téléchargement de $name $version" curl -fsSL "$url" -o "$archive" || return 1
    if ! is_true "$DRY_RUN"; then
      if ! printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check --status; then
        die "Somme SHA-256 invalide pour $name."
        return 1
      fi
      local shell_major
      shell_major="$(gnome-shell --version | awk '{print $NF}' | cut -d. -f1)"
      if ! theme_validate_extension_archive "$archive" "$uuid" "$version" "$shell_major"; then
        die "Métadonnées invalides ou incompatibles pour $name."
        return 1
      fi
      run_cmd "Installation de l'extension $name" gnome-extensions install --force "$archive" || return 1
      theme_installed_extension_is_compatible "$uuid" "$version" || {
        die "L'extension installée ne correspond pas au manifeste : $name."
        return 1
      }
    fi
  else
    log_ok "Extension déjà installée : $name"
  fi

  if [[ "$enable" == "true" ]]; then
    if is_true "$DRY_RUN"; then
      log_info "[dry-run] L'extension $name serait activée."
    elif gnome-extensions list --enabled | grep -Fxq "$uuid"; then
      log_ok "Extension déjà activée : $name"
    else
      theme_enable_extension "$uuid" "$name" || return 1
      state_set logout_required true || return 1
    fi
  fi
  [[ "$version" == "0" ]] || state_set "theme_extension_${version_tag}" "$uuid:$version" || return 1
}

install_theme_extensions() {
  local raw uuid name package version version_tag checksum enable extra
  local -a failures=()
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    [[ -z "$raw" || "$raw" == \#* ]] && continue
    IFS='|' read -r uuid name package version version_tag checksum enable extra <<<"$raw"
    if ! install_one_theme_extension "$uuid" "$name" "$package" "$version" "$version_tag" "$checksum" "$enable"; then
      log_error "Extension non appliquée, poursuite du profil : $name"
      failures+=("$name")
    fi
  done <"$THEME_EXTENSIONS_PROFILE"

  if ((${#failures[@]} > 0)); then
    local failure_summary=""
    local failure
    for failure in "${failures[@]}"; do
      [[ -z "$failure_summary" ]] || failure_summary+=", "
      failure_summary+="$failure"
    done
    state_set theme_extension_failures "$failure_summary"
    log_warn "Extensions en échec (${#failures[@]}) : $failure_summary"
  else
    state_set theme_extension_failures ""
    log_ok "Toutes les extensions demandées sont installées."
  fi
}

theme_values_equal() {
  local expected="$1" actual="$2"
  [[ "$expected" == "$actual" ]] && return 0
  if [[ "$expected" =~ ^-?[0-9]+([.][0-9]+)?$ && "$actual" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    awk -v a="$expected" -v b="$actual" 'BEGIN {d=a-b; if (d<0) d=-d; exit !(d<0.000001)}'
    return
  fi
  return 1
}

apply_theme_gsettings() {
  local raw schema key target uuid extra current actual
  local legacy_dark=false
  local -a failures=()
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    [[ -z "$raw" || "$raw" == \#* ]] && continue
    IFS='|' read -r schema key target uuid extra <<<"$raw"

    if [[ "$schema.$key" == "org.gnome.desktop.interface.gtk-theme" && "$legacy_dark" == "true" ]]; then
      target="'Adwaita-dark'"
    fi

    if [[ "$schema.$key" == "org.gnome.mutter.edge-tiling" ]] &&
      ! gnome-extensions info tiling-assistant@leleat-on-github >/dev/null 2>&1; then
      log_info "Tiling Assistant absent : edge-tiling Fedora est conservé."
      continue
    fi

    if ! theme_schema_has_key "$schema" "$key" "$uuid"; then
      if [[ "$schema.$key" == "org.gnome.desktop.interface.color-scheme" ]]; then
        legacy_dark=true
        state_set theme_legacy_dark true
        log_warn "color-scheme est indisponible : utilisation du thème GTK Adwaita-dark compatible."
        continue
      fi
      if [[ -n "$uuid" ]]; then
        log_warn "Réglage d'extension ignoré car indisponible : $schema.$key ($uuid)"
      else
        log_warn "Réglage GNOME ignoré car indisponible : $schema.$key"
      fi
      failures+=("$schema.$key")
      continue
    fi
    if ! theme_gsettings "$uuid" writable "$schema" "$key" | grep -Fxq true; then
      log_warn "Réglage GNOME verrouillé par une politique : $schema.$key"
      failures+=("$schema.$key")
      continue
    fi

    current="$(theme_gsettings "$uuid" get "$schema" "$key")"
    if theme_values_equal "$target" "$current"; then
      log_ok "Déjà conforme : $schema.$key = $current"
      continue
    fi
    log_info "Réglage GNOME : $schema.$key"
    log_info "  valeur actuelle : $current"
    log_info "  valeur cible     : $target"
    if ! run_cmd "Application de $schema.$key" theme_gsettings "$uuid" set "$schema" "$key" "$target"; then
      failures+=("$schema.$key")
      continue
    fi
    if ! is_true "$DRY_RUN"; then
      actual="$(theme_gsettings "$uuid" get "$schema" "$key")"
      if ! theme_values_equal "$target" "$actual"; then
        log_warn "Relecture différente pour $schema.$key : $actual"
        failures+=("$schema.$key")
      fi
    fi
  done <"$THEME_GSETTINGS_PROFILE"

  if [[ "$legacy_dark" != "true" ]]; then
    state_set theme_legacy_dark false
  fi
  local failure_summary="" failure
  for failure in "${failures[@]}"; do
    [[ -z "$failure_summary" ]] || failure_summary+=", "
    failure_summary+="$failure"
  done
  state_set theme_setting_failures "$failure_summary"
  [[ -z "$failure_summary" ]] || log_warn "Réglages GNOME non appliqués : $failure_summary"
}

configure_theme_zsh() {
  local zshrc="$HOME/.zshrc"
  local managed_target temporary
  managed_target="$(theme_managed_zsh_target)"
  temporary="$RUNTIME_TMP/theme-zshrc"

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Le module Zsh géré serait copié dans $managed_target."
    log_info "[dry-run] Un bloc unique serait ajouté à $zshrc sans remplacer le reste du fichier."
    return 0
  fi

  [[ -e "$zshrc" ]] || touch "$zshrc"
  [[ -f "$zshrc" && ! -L "$zshrc" ]] || {
    die "$zshrc doit être un fichier régulier."
    return 1
  }
  mkdir -p "$(dirname -- "$managed_target")"
  install -m 0644 "$THEME_ZSH_SOURCE" "$managed_target"

  awk '
    function managed_block() {
      print "# >>> fedora-post-install theme zsh >>>"
      print "source \"${XDG_CONFIG_HOME:-$HOME/.config}/fedora-post-install/zsh/managed.zsh\""
      print "# <<< fedora-post-install theme zsh <<<"
    }
    BEGIN {inside = 0; inserted = 0}
    /^# >>> fedora-post-install (theme )?zsh >>>$/ {inside = 1; next}
    /^# <<< fedora-post-install (theme )?zsh <<</ {inside = 0; next}
    inside {next}
    /oh-my-zsh\.sh/ && /^[[:space:]]*(source|\.)[[:space:]]/ {
      if (!inserted) {managed_block(); inserted = 1}
      next
    }
    /\/usr\/share\/zsh-(autosuggestions|syntax-highlighting)\// {next}
    {print}
    END {
      if (!inserted) {
        print ""
        managed_block()
      }
    }
  ' "$zshrc" >"$temporary"
  chmod --reference="$zshrc" "$temporary"
  mv -f -- "$temporary" "$zshrc"

  run_cmd "Validation de la syntaxe Zsh" zsh -n "$zshrc" "$managed_target"
  run_quiet "Validation du module Zsh dans un shell isolé" zsh -dfi -c 'source "$1"; exit' zsh "$managed_target"
  log_ok "Profil Zsh appliqué sans modifier les personnalisations hors du bloc géré."
}

validate_theme_result() {
  if is_true "$DRY_RUN"; then
    log_info "[dry-run] La relecture finale du profil sera effectuée après son application réelle."
    return 0
  fi

  if [[ "$APPLY_THEME" == "true" ]]; then
    local raw schema key target uuid extra actual
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      raw="${raw%$'\r'}"
      [[ -z "$raw" || "$raw" == \#* ]] && continue
      IFS='|' read -r schema key target uuid extra <<<"$raw"
      theme_schema_has_key "$schema" "$key" "$uuid" || continue
      if [[ "$schema.$key" == "org.gnome.desktop.interface.gtk-theme" &&
        "$(state_get theme_legacy_dark false)" == "true" ]]; then
        target="'Adwaita-dark'"
      fi
      actual="$(theme_gsettings "$uuid" get "$schema" "$key")"
      theme_values_equal "$target" "$actual" || {
        die "Validation theme échouée : $schema.$key vaut $actual."
        return 1
      }
    done <"$THEME_GSETTINGS_PROFILE"
    fc-match Inter >/dev/null || {
      die "Police Inter introuvable après application du thème."
      return 1
    }
    fc-match "Fira Code" >/dev/null || {
      die "Police Fira Code introuvable après application du thème."
      return 1
    }
  fi

  if [[ "$APPLY_ZSH_CONFIG" == "true" ]]; then
    zsh -n "$HOME/.zshrc" "$(theme_managed_zsh_target)" || {
      die "Validation finale Zsh échouée."
      return 1
    }
  fi

  if [[ "$APPLY_GNOME_EXTENSIONS" == "true" ]]; then
    local failures
    failures="$(state_get theme_extension_failures)"
    [[ -z "$failures" ]] || log_warn "Profil terminé avec extensions à revoir : $failures"
    state_set logout_required true
  fi
  local setting_failures
  setting_failures="$(state_get theme_setting_failures)"
  [[ -z "$setting_failures" ]] || log_warn "Profil terminé avec réglages GNOME à revoir : $setting_failures"
  log_ok "Validation du profil GNOME/Zsh terminée."
}

theme_profile_signature() {
  {
    printf '%s\n' "$APPLY_THEME" "$APPLY_GNOME_EXTENSIONS" "$APPLY_ZSH_CONFIG"
    sha256sum "$THEME_GSETTINGS_PROFILE" "$THEME_EXTENSIONS_PROFILE" "$THEME_ZSH_SOURCE"
  } | sha256sum | awk '{print $1}'
}

reset_theme_checkpoints_if_needed() {
  local current previous
  current="$(theme_profile_signature)"
  previous="$(state_get theme_profile_signature)"
  [[ -z "$previous" || "$previous" == "$current" ]] && return 0

  log_warn "Le profil theme ou ses options ont changé : une nouvelle sauvegarde et une nouvelle application sont nécessaires."
  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Les checkpoints theme existants seraient réinitialisés."
    return 0
  fi

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
    rm -f -- "$path"
  done
}

reset_failed_theme_checkpoints() {
  local failures
  failures="$(state_get theme_extension_failures)"
  [[ -n "$failures" ]] || return 0
  log_warn "Nouvelle tentative des extensions précédemment en échec : $failures"
  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Les checkpoints theme.extensions et theme.validate seraient réinitialisés."
    return 0
  fi

  local step path
  for step in theme.extensions theme.validate; do
    path="$STATE_STEPS_DIR/$step"
    [[ ! -e "$path" || (-f "$path" && ! -L "$path") ]] || {
      die "Checkpoint theme non régulier : $path"
      return 1
    }
    rm -f -- "$path"
  done
}

stage_theme() {
  if [[ "$APPLY_THEME" != "true" && "$APPLY_GNOME_EXTENSIONS" != "true" && "$APPLY_ZSH_CONFIG" != "true" ]]; then
    log_info "Profil GNOME/Zsh désactivé dans la configuration."
    return 0
  fi

  reset_theme_checkpoints_if_needed
  reset_failed_theme_checkpoints
  run_step_once theme.preflight "Prévalidation du profil GNOME/Zsh" theme_preflight
  run_step_once theme.backup "Sauvegarde du profil utilisateur actuel" backup_theme_state
  run_if_enabled APPLY_GNOME_EXTENSIONS theme.extensions "Extensions GNOME du profil" install_theme_extensions
  run_if_enabled APPLY_THEME theme.gnome "Apparence et comportements GNOME" apply_theme_gsettings
  run_if_enabled APPLY_ZSH_CONFIG theme.zsh "Configuration Zsh du profil" configure_theme_zsh
  run_step_once theme.validate "Validation du profil GNOME/Zsh" validate_theme_result
  state_set theme_profile_signature "$(theme_profile_signature)"

  if [[ "$(state_get logout_required false)" == "true" ]]; then
    log_warn "Déconnectez-vous puis reconnectez-vous après la fin du script pour charger les nouvelles extensions GNOME."
  fi
  local backup_dir
  backup_dir="$(state_get theme_backup_dir)"
  [[ -z "$backup_dir" || "$backup_dir" == "simulation" ]] ||
    log_info "Restauration possible avec : ./scripts/restore-theme.sh"
}

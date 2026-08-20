#!/usr/bin/env bash

# Parseur strict de config.ini. Les valeurs sont affectées uniquement à des clés
# connues avec printf -v ; le fichier n'est jamais chargé avec source ou eval.

declare -Ag CONFIG_DEFAULTS=(
  [CONFIG_VERSION]="1"
  [AUTO_CONFIRM_SAFE_ACTIONS]="false"
  [AUTO_CONFIRM_ALL_ACTIONS]="false"
  [AUTO_REBOOT]="false"
  [INSTALL_BRAVE]="false"
  [INSTALL_BITWARDEN]="false"
  [INSTALL_CLAMAV]="false"
  [INSTALL_CLAMUI]="false"
  [INSTALL_PINTA]="false"
  [INSTALL_UPSCAYL]="false"
  [INSTALL_MPV]="false"
  [INSTALL_RUSTDESK]="false"
  [INSTALL_GEARLEVER]="false"
  [INSTALL_VSCODE]="false"
  [INSTALL_DESKTOP_PLUS]="false"
  [INSTALL_BRUNO]="false"
  [INSTALL_DOCKER]="false"
  [INSTALL_NODE]="false"
  [INSTALL_RTK]="false"
  [INSTALL_CLI_TOOLS]="false"
  [INSTALL_STEAM]="false"
  [INSTALL_BOTTLES]="false"
  [INSTALL_LUTRIS]="false"
  [INSTALL_HEROIC]="false"
  [INSTALL_GAMEMODE]="false"
  [INSTALL_GAMESCOPE]="false"
  [NVIDIA_DRIVER]="auto"
  [INSTALL_HARDWARE_CODECS]="false"
  [INSTALL_CACHYOS]="false"
  [INSTALL_CACHYOS_ADDONS]="false"
)

declare -Ag CONFIG_TYPES=(
  [CONFIG_VERSION]="version"
  [NVIDIA_DRIVER]="nvidia_mode"
)

declare -ag CONFIG_KEYS=(
  CONFIG_VERSION
  AUTO_CONFIRM_SAFE_ACTIONS
  AUTO_CONFIRM_ALL_ACTIONS
  AUTO_REBOOT
  INSTALL_BRAVE
  INSTALL_BITWARDEN
  INSTALL_CLAMAV
  INSTALL_CLAMUI
  INSTALL_PINTA
  INSTALL_UPSCAYL
  INSTALL_MPV
  INSTALL_RUSTDESK
  INSTALL_GEARLEVER
  INSTALL_VSCODE
  INSTALL_DESKTOP_PLUS
  INSTALL_BRUNO
  INSTALL_DOCKER
  INSTALL_NODE
  INSTALL_RTK
  INSTALL_CLI_TOOLS
  INSTALL_STEAM
  INSTALL_BOTTLES
  INSTALL_LUTRIS
  INSTALL_HEROIC
  INSTALL_GAMEMODE
  INSTALL_GAMESCOPE
  NVIDIA_DRIVER
  INSTALL_HARDWARE_CODECS
  INSTALL_CACHYOS
  INSTALL_CACHYOS_ADDONS
)

config_error() {
  printf 'Erreur de configuration : %s\n' "$*" >&2
  return 1
}

set_config_defaults() {
  local key
  for key in "${CONFIG_KEYS[@]}"; do
    printf -v "$key" '%s' "${CONFIG_DEFAULTS[$key]}"
  done
}

validate_config_value() {
  local key="$1"
  local value="$2"
  local type="${CONFIG_TYPES[$key]:-boolean}"

  case "$type" in
    boolean)
      if [[ "$value" != "true" && "$value" != "false" ]]; then
        config_error "$key accepte uniquement true ou false, pas « $value »."
        return 1
      fi
      ;;
    version)
      if [[ "$value" != "1" ]]; then
        config_error "CONFIG_VERSION=$value n'est pas pris en charge (version attendue : 1)."
        return 1
      fi
      ;;
    nvidia_mode)
      if [[ "$value" != "auto" && "$value" != "disabled" ]]; then
        config_error "NVIDIA_DRIVER accepte uniquement auto ou disabled."
        return 1
      fi
      ;;
    *)
      config_error "Type interne inconnu pour $key : $type."
      return 1
      ;;
  esac
}

set_config_value() {
  local key="$1"
  local value="$2"

  if [[ ! -v "CONFIG_DEFAULTS[$key]" ]]; then
    config_error "clé inconnue « $key »."
    return 1
  fi
  validate_config_value "$key" "$value" || return 1
  printf -v "$key" '%s' "$value"
}

parse_config_file() {
  local config_path="$1"
  if [[ ! -f "$config_path" || -L "$config_path" ]]; then
    config_error "fichier régulier introuvable : $config_path"
    return 1
  fi

  local raw_line line key value
  local line_number=0
  declare -A seen=()

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    ((line_number += 1))
    raw_line="${raw_line%$'\r'}"
    line="$(trim "$raw_line")"

    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *"="* ]]; then
      config_error "$config_path:$line_number ne contient pas de signe =."
      return 1
    fi

    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"

    if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      config_error "$config_path:$line_number contient une clé invalide « $key »."
      return 1
    fi
    if [[ -z "$value" ]]; then
      config_error "$config_path:$line_number contient une valeur vide pour $key."
      return 1
    fi
    if [[ -n "${seen[$key]:-}" ]]; then
      config_error "$config_path:$line_number redéfinit la clé $key."
      return 1
    fi

    set_config_value "$key" "$value" || return 1
    seen["$key"]=1
  done <"$config_path"

  if [[ -z "${seen[CONFIG_VERSION]:-}" ]]; then
    config_error "CONFIG_VERSION doit être explicitement présent dans $config_path."
    return 1
  fi
}

apply_config_override() {
  local assignment="$1"
  if [[ "$assignment" != *"="* ]]; then
    config_error "--set attend une valeur KEY=VALUE."
    return 1
  fi

  local key value
  key="$(trim "${assignment%%=*}")"
  value="$(trim "${assignment#*=}")"
  if [[ -z "$key" || -z "$value" ]]; then
    config_error "--set attend une clé et une valeur non vides."
    return 1
  fi
  set_config_value "$key" "$value"
}

resolve_config_dependencies() {
  if [[ "$AUTO_CONFIRM_ALL_ACTIONS" == "true" && "$AUTO_CONFIRM_SAFE_ACTIONS" != "true" ]]; then
    AUTO_CONFIRM_SAFE_ACTIONS=true
    log_info "Dépendance activée : le mode entièrement automatique inclut les actions sûres."
  fi

  if [[ "$INSTALL_CLAMUI" == "true" && "$INSTALL_CLAMAV" != "true" ]]; then
    INSTALL_CLAMAV=true
    log_info "Dépendance activée : INSTALL_CLAMAV=true est requis par ClamUI."
  fi

  if [[ "$INSTALL_CACHYOS" != "true" && "$INSTALL_CACHYOS_ADDONS" == "true" ]]; then
    log_info "INSTALL_CACHYOS_ADDONS=true est ignoré car INSTALL_CACHYOS=false."
  fi
}

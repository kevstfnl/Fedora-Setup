#!/usr/bin/env bash

# Étapes Fedora générales. Chaque opération est idempotente et possède son
# propre checkpoint pour qu'une reprise n'ait pas à rejouer tout un groupe.

HAS_AMD_GPU=false
HAS_INTEL_GPU=false
HAS_NVIDIA_GPU=false
GPU_DESCRIPTION=""
SECURE_BOOT_STATE="unknown"

configure_static_hostname() {
  if [[ "$HOSTNAME" == "disabled" ]]; then
    log_info "Configuration du hostname désactivée."
    return 0
  fi

  local current_static
  current_static="$(hostnamectl --static 2>/dev/null || true)"

  if [[ "$current_static" == "$HOSTNAME" ]]; then
    log_ok "Hostname statique déjà configuré : $HOSTNAME"
    return 0
  fi

  confirm_action safe "Définir le hostname statique sur « $HOSTNAME » ?" || return 0

  run_cmd "Configuration du hostname statique : $HOSTNAME" sudo hostnamectl set-hostname "$HOSTNAME"

  if ! is_true "$DRY_RUN"; then
    [[ "$(hostnamectl --static 2>/dev/null)" == "$HOSTNAME" ]] ||
      die "Échec de la configuration du hostname."

    log_ok "Hostname statique configuré : $HOSTNAME"
  fi
}

run_if_enabled() {
  local flag_name="$1"
  local step="$2"
  local description="$3"
  local function_name="$4"
  local value="${!flag_name}"

  if [[ "$value" == "true" ]]; then
    run_step_once "$step" "$description" "$function_name"
  else
    log_info "Désactivé par $flag_name=false : $description"
  fi
}

ensure_optional_dnf_package() {
  local package="$1"
  if package_installed "$package"; then
    log_ok "Paquet optionnel déjà installé : $package"
  elif package_available "$package"; then
    ensure_dnf_packages "$package"
  else
    log_warn "Paquet optionnel indisponible pour Fedora 44 : $package"
  fi
}

read_os_release_value() {
  local expected_key="$1"
  awk -F= -v expected="$expected_key" '
    $1 == expected {
      value = substr($0, index($0, "=") + 1)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' /etc/os-release
}

detect_hardware() {
  GPU_DESCRIPTION="$(lspci -nn 2>/dev/null | awk 'tolower($0) ~ /vga|3d controller|display controller/ {print}')"

  if grep -Eqi 'AMD|ATI' <<<"$GPU_DESCRIPTION"; then
    HAS_AMD_GPU=true
  fi
  if grep -Eqi 'Intel' <<<"$GPU_DESCRIPTION"; then
    HAS_INTEL_GPU=true
  fi
  if grep -Eqi 'NVIDIA' <<<"$GPU_DESCRIPTION"; then
    HAS_NVIDIA_GPU=true
  fi

  log_info "GPU détectés :"
  if [[ -n "$GPU_DESCRIPTION" ]]; then
    while IFS= read -r gpu; do log_info "  $gpu"; done <<<"$GPU_DESCRIPTION"
  else
    log_warn "  Aucun contrôleur graphique identifié par lspci."
  fi

  state_set has_amd_gpu "$HAS_AMD_GPU"
  state_set has_intel_gpu "$HAS_INTEL_GPU"
  state_set has_nvidia_gpu "$HAS_NVIDIA_GPU"
}

detect_secure_boot() {
  if ! command -v mokutil >/dev/null 2>&1; then
    SECURE_BOOT_STATE="unknown"
    log_warn "mokutil est absent : état Secure Boot inconnu."
  else
    local output
    output="$(mokutil --sb-state 2>&1 || true)"
    if grep -qi 'enabled' <<<"$output"; then
      SECURE_BOOT_STATE="enabled"
    elif grep -qi 'disabled' <<<"$output"; then
      SECURE_BOOT_STATE="disabled"
    else
      SECURE_BOOT_STATE="unknown"
    fi
    log_info "Secure Boot : $output"
  fi
  state_set secure_boot "$SECURE_BOOT_STATE"
}

system_preflight() {
  log_step "Prévalidation du système"
  require_non_root

  local command_name
  for command_name in bash awk sed grep sort tail tee curl rpm dnf sudo flock findmnt df sha256sum lspci; do
    require_command "$command_name"
  done

  local os_id version_id variant_id architecture
  os_id="$(read_os_release_value ID)"
  version_id="$(read_os_release_value VERSION_ID)"
  variant_id="$(read_os_release_value VARIANT_ID)"
  architecture="$(uname -m)"

  [[ "$os_id" == "fedora" ]] || die "Distribution non prise en charge : ${os_id:-inconnue}."
  [[ "$version_id" == "44" ]] || die "Fedora 44 est requise ; version détectée : ${version_id:-inconnue}."
  [[ "$variant_id" == "workstation" ]] || die "Fedora Workstation est requise ; variante détectée : ${variant_id:-inconnue}."
  [[ "$architecture" == "x86_64" ]] || die "Architecture x86_64 requise ; architecture détectée : $architecture."
  [[ ! -e /run/ostree-booted ]] || die "Une édition Atomic/rpm-ostree n'est pas prise en charge."
  rpm -q gnome-shell >/dev/null 2>&1 || die "GNOME Shell n'est pas installé."

  if is_true "$DRY_RUN"; then
    if sudo -n true >/dev/null 2>&1; then
      log_ok "sudo est déjà autorisé pour cette session."
    else
      log_warn "[dry-run] sudo nécessitera probablement une authentification lors de l'exécution réelle."
    fi
  else
    run_cmd "Validation de l'accès sudo" sudo -v
  fi

  if curl -fsSIL --max-time 15 https://fedoraproject.org >/dev/null; then
    log_ok "Connectivité HTTPS validée."
  else
    die "Connexion HTTPS indisponible. Vérifiez le réseau avant de continuer."
  fi

  local root_available_kib
  root_available_kib="$(df -Pk / | awk 'NR == 2 {print $4}')"
  [[ "$root_available_kib" =~ ^[0-9]+$ ]] || die "Impossible de mesurer l'espace disque disponible."
  ((root_available_kib >= 5 * 1024 * 1024)) ||
    die "Moins de 5 Gio sont disponibles sur la racine."
  log_info "Espace disponible sur / : $((root_available_kib / 1024)) Mio."

  local mount_description
  mount_description="$(findmnt -no FSTYPE,OPTIONS /)"
  log_info "Système de fichiers racine : $mount_description"
  state_set root_mount "$mount_description"

  detect_hardware
  detect_secure_boot

  if dnf repolist --enabled 2>/dev/null | grep -qi rawhide; then
    die "Un dépôt Rawhide est activé sur Fedora stable."
  fi

  log_ok "Prévalidation Fedora terminée."
}

configure_dnf() {
  local target="/etc/dnf/libdnf5.conf.d/90-fedora-setup.conf"
  local content
  content="$(cat <<EOF
# $MANAGED_MARKER
[main]
max_parallel_downloads=10
EOF
)"

  if [[ -f "$target" ]] && cmp -s <(printf '%s\n' "$content") "$target"; then
    log_ok "Configuration DNF déjà conforme."
    return 0
  fi

  confirm_action safe "Ajouter le réglage DNF max_parallel_downloads=10 ?" || return 0
  install_managed_content "$target" 0644 "$content"$'\n'
}

audit_btrfs() {
  local filesystem options
  filesystem="$(findmnt -no FSTYPE /)"
  options="$(findmnt -no OPTIONS /)"
  log_info "Type de la racine : $filesystem"
  log_info "Options de montage : $options"

  if [[ "$filesystem" == "btrfs" ]]; then
    if grep -q 'compress=zstd' <<<"$options"; then
      log_ok "Compression Btrfs zstd déjà active ; aucune modification."
    else
      log_warn "Btrfs détecté sans compression zstd visible. Le script ne modifie pas fstab automatiquement."
    fi
  else
    log_info "La racine n'utilise pas Btrfs ; audit terminé sans action."
  fi
}

upgrade_fedora() {
  confirm_action safe "Mettre Fedora à jour avec dnf upgrade --refresh ?" || return 0
  run_safe_dnf "Mise à jour complète de Fedora" upgrade --refresh
  run_cmd "Vérification de la base RPM/DNF" sudo dnf check

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] dnf needs-restarting serait exécuté après la mise à jour."
    return 0
  fi

  local output rc
  if output="$(dnf needs-restarting 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] && log_info "needs-restarting : $line"
  done <<<"$output"

  case "$rc" in
    0) log_ok "Aucun redémarrage système requis par DNF." ;;
    1)
      log_warn "DNF recommande un redémarrage."
      state_set reboot_recommended true
      ;;
    *) die "dnf needs-restarting a échoué avec le code $rc." ;;
  esac
}

stage_prepare() {
  run_step_once prepare.hostname "Configuration du nom de machine" configure_static_hostname
  run_step_once prepare.dnf "Configuration prudente de DNF5" configure_dnf
  run_step_once prepare.btrfs "Audit du système de fichiers" audit_btrfs
  run_step_once prepare.upgrade "Mise à jour initiale de Fedora" upgrade_fedora
}

enable_fedora_third_party() {
  if ! command -v fedora-third-party >/dev/null 2>&1; then
    log_warn "fedora-third-party est absent ; activation ignorée."
    return 0
  fi
  confirm_action safe "Activer la sélection de dépôts tiers proposée par Fedora ?" || return 0
  run_cmd "Activation des dépôts tiers Fedora" sudo fedora-third-party enable
}

rpmfusion_is_needed() {
  [[ "$INSTALL_HARDWARE_CODECS" == "true" ||
    "$INSTALL_STEAM" == "true" ||
    "$NVIDIA_DRIVER" == "auto" ]]
}

enable_rpmfusion() {
  if package_installed rpmfusion-free-release && package_installed rpmfusion-nonfree-release; then
    log_ok "RPM Fusion Free et Nonfree sont déjà actifs."
    return 0
  fi

  local fedora_release
  fedora_release="$(rpm -E %fedora)"
  [[ "$fedora_release" == "44" ]] || die "Valeur rpm %fedora inattendue : $fedora_release."

  confirm_action safe "Activer RPM Fusion Free et Nonfree pour Fedora 44 ?" || return 1
  local -a release_urls=(
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_release}.noarch.rpm"
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_release}.noarch.rpm"
  )
  run_safe_dnf "Installation des dépôts RPM Fusion" install "${release_urls[@]}"

  if ! is_true "$DRY_RUN"; then
    package_installed rpmfusion-free-release || die "RPM Fusion Free n'a pas été installé."
    package_installed rpmfusion-nonfree-release || die "RPM Fusion Nonfree n'a pas été installé."
  fi
}

enable_flathub() {
  require_command flatpak
  if flatpak remotes --system --columns=name 2>/dev/null | grep -qx flathub; then
    log_ok "Flathub est déjà configuré avec une portée système."
    return 0
  fi
  confirm_action safe "Ajouter Flathub avec une portée système ?" || return 1
  run_cmd "Ajout du dépôt Flathub" flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo
}

install_multimedia_codecs() {
  run_cmd "Activation du dépôt Cisco OpenH264" sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1

  if package_installed ffmpeg-free; then
    confirm_action sensitive "Remplacer ffmpeg-free par ffmpeg RPM Fusion avec --allowerasing ?" ||
      die "Le remplacement de ffmpeg-free a été refusé."
    run_sensitive_dnf "Remplacement de ffmpeg-free" swap ffmpeg-free ffmpeg --allowerasing
  else
    ensure_dnf_packages ffmpeg
  fi

  local -a gstreamer_packages=(
    gstreamer1-plugins-good
    gstreamer1-plugins-bad-free
    gstreamer1-plugins-bad-freeworld
    gstreamer1-plugins-ugly
    gstreamer1-plugins-ugly-free
    gstreamer1-plugin-openh264
    gstreamer1-plugin-libav
  )
  ensure_dnf_packages "${gstreamer_packages[@]}"
}

install_amd_video_stack() {
  ensure_dnf_packages mesa-vulkan-drivers libva-utils vulkan-tools

  if package_installed mesa-va-drivers; then
    confirm_action sensitive "Remplacer mesa-va-drivers par mesa-va-drivers-freeworld pour AMD ?" ||
      die "Le remplacement du pilote VA-API AMD a été refusé."
    run_sensitive_dnf "Activation des codecs VA-API AMD" swap mesa-va-drivers mesa-va-drivers-freeworld
  else
    ensure_dnf_packages mesa-va-drivers-freeworld
  fi
}

install_intel_video_stack() {
  ensure_dnf_packages libva-utils vulkan-tools
  if grep -Eqi 'GMA|Ironlake|Sandy Bridge|Ivy Bridge|Haswell' <<<"$GPU_DESCRIPTION"; then
    ensure_dnf_packages libva-intel-driver
  else
    ensure_dnf_packages intel-media-driver
  fi
}

select_nvidia_branch() {
  local installed
  for installed in akmod-nvidia akmod-nvidia-580xx akmod-nvidia-470xx akmod-nvidia-390xx; do
    if package_installed "$installed"; then
      case "$installed" in
        akmod-nvidia) printf 'current' ;;
        akmod-nvidia-*) printf '%s' "${installed#akmod-nvidia-}" ;;
      esac
      return 0
    fi
  done

  case "$GPU_DESCRIPTION" in
    *RTX* | *"GTX 16"* | *"Ada Lovelace"* | *"Blackwell"*) printf 'current' ;;
    *"GTX 10"* | *"GTX 9"* | *"GTX 750"* | *"Maxwell"* | *"Pascal"*) printf '580xx' ;;
    *"GTX 6"* | *"GTX 7"* | *"GT 710"* | *"Kepler"*) printf '470xx' ;;
    *"GTX 4"* | *"GTX 5"* | *"Fermi"*) printf '390xx' ;;
    *)
      log_warn "La branche NVIDIA ne peut pas être déterminée avec certitude depuis : $GPU_DESCRIPTION"
      if [[ ! -t 0 ]]; then
        die "Sélection NVIDIA interactive requise."
        return 1
      fi
      local choice
      printf 'Choisissez la branche NVIDIA [current/580xx/470xx/390xx/skip] : '
      read -r choice
      case "$choice" in
        current | 580xx | 470xx | 390xx) printf '%s' "$choice" ;;
        skip) printf 'skip' ;;
        *) die "Branche NVIDIA invalide : $choice" ;;
      esac
      ;;
  esac
}

install_nvidia_driver() {
  if [[ "$HAS_NVIDIA_GPU" != "true" ]]; then
    log_info "Aucun GPU NVIDIA détecté."
    return 0
  fi
  if [[ "$NVIDIA_DRIVER" == "disabled" ]]; then
    log_warn "GPU NVIDIA détecté, mais NVIDIA_DRIVER=disabled."
    return 0
  fi
  if [[ "$SECURE_BOOT_STATE" == "enabled" ]]; then
    die "Secure Boot est actif. Préparez l'enrôlement MOK RPM Fusion avant l'installation NVIDIA."
    return 1
  fi

  local branch suffix
  branch="$(select_nvidia_branch)"
  [[ "$branch" != "skip" ]] || {
    log_warn "Installation NVIDIA ignorée par l'utilisateur."
    return 0
  }
  suffix=""
  [[ "$branch" == "current" ]] || suffix="-$branch"
  log_info "Branche NVIDIA retenue : $branch"
  state_set nvidia_branch "$branch"

  local -a nvidia_packages=(
    "akmod-nvidia${suffix}"
    "xorg-x11-drv-nvidia${suffix}-cuda"
    "xorg-x11-drv-nvidia${suffix}-cuda-libs"
    libva-nvidia-driver
    vdpauinfo
    libva-utils
    vulkan-tools
  )
  ensure_dnf_packages "${nvidia_packages[@]}"

  if ! is_true "$DRY_RUN"; then
    require_command grubby
    local target_kernel_path target_kernel_version
    target_kernel_path="$(sudo grubby --default-kernel)"
    validate_kernel_path "$target_kernel_path" ||
      die "Le noyau prévu au prochain démarrage est invalide : $target_kernel_path"
    target_kernel_version="${target_kernel_path#/boot/vmlinuz-}"

    log_info "Noyau ciblé pour NVIDIA : $target_kernel_version"
    state_set nvidia_kernel_target "$target_kernel_version"
    ensure_dnf_packages "kernel-devel-$target_kernel_version"
    run_cmd "Compilation NVIDIA pour $target_kernel_version" sudo akmods --force --rebuild --kernels "$target_kernel_version"

    # Toujours interroger le noyau ciblé : sans -k, modinfo utilise le noyau
    # courant et produit un faux négatif après une mise à jour du noyau.
    modinfo -k "$target_kernel_version" -F version nvidia 2>&1 | tee -a "$LOG_FILE"
    modinfo -k "$target_kernel_version" -F signer nvidia 2>&1 | tee -a "$LOG_FILE" || true
  fi
  state_set reboot_recommended true
}

install_hardware_video_stack() {
  if [[ "$HAS_AMD_GPU" == "true" ]]; then
    install_amd_video_stack
  fi
  if [[ "$HAS_INTEL_GPU" == "true" ]]; then
    install_intel_video_stack
  fi
  if [[ "$HAS_AMD_GPU" != "true" && "$HAS_INTEL_GPU" != "true" && "$HAS_NVIDIA_GPU" != "true" ]]; then
    log_warn "Aucune pile vidéo spécifique n'a été sélectionnée."
  fi
}

stage_repositories_and_drivers() {
  run_step_once repositories.fedora-third-party "Dépôts tiers Fedora" enable_fedora_third_party
  if rpmfusion_is_needed; then
    run_step_once repositories.rpmfusion "Activation de RPM Fusion" enable_rpmfusion
  fi
  run_step_once repositories.flathub "Activation de Flathub" enable_flathub
  run_if_enabled INSTALL_HARDWARE_CODECS repositories.codecs "Codecs multimédias" install_multimedia_codecs
  run_if_enabled INSTALL_HARDWARE_CODECS repositories.video "Accélération vidéo matérielle" install_hardware_video_stack
  if [[ "$HAS_NVIDIA_GPU" == "true" && "$NVIDIA_DRIVER" == "auto" ]]; then
    run_step_once repositories.nvidia "Pilote NVIDIA adapté au matériel" install_nvidia_driver
  elif [[ "$HAS_NVIDIA_GPU" == "true" ]]; then
    log_warn "GPU NVIDIA détecté, mais NVIDIA_DRIVER=disabled."
  else
    log_info "Aucun GPU NVIDIA : étape pilote propriétaire ignorée."
  fi

  if dnf repolist --enabled 2>/dev/null | grep -qi rawhide; then
    die "Un dépôt Rawhide a été détecté après configuration."
  fi
}

install_gnome_tools() {
  ensure_dnf_packages gnome-tweaks gnome-extensions-app
  local extension_package
  local -a extension_packages=(
    gnome-shell-extension-user-theme
    gnome-shell-extension-appindicator
    gnome-shell-extension-dash-to-dock
    gnome-shell-extension-blur-my-shell
  )
  for extension_package in "${extension_packages[@]}"; do
    ensure_optional_dnf_package "$extension_package"
  done
  ensure_flatpak_app com.mattjakeman.ExtensionManager
}

install_appimage_support() { ensure_dnf_packages fuse-libs; }
install_gearlever() { ensure_flatpak_app it.mijorus.gearlever; }

configure_zsh_file() {
  local zshrc="$HOME/.zshrc"
  local temporary="$RUNTIME_TMP/zshrc"
  local backup="$HOME/.zshrc.fedora-post-install.bak"

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] ~/.zshrc serait configuré avec le thème clean et les plugins Fedora."
    return 0
  fi

  [[ -e "$zshrc" ]] || touch "$zshrc"
  [[ -f "$zshrc" && ! -L "$zshrc" ]] || die "$zshrc doit être un fichier régulier."
  [[ -e "$backup" ]] || cp -p -- "$zshrc" "$backup"

  awk '
    BEGIN {inside = 0; theme = 0}
    /^# >>> fedora-post-install zsh >>>$/ {inside = 1; next}
    /^# <<< fedora-post-install zsh <<</ {inside = 0; next}
    inside {next}
    /^ZSH_THEME=/ {print "ZSH_THEME=\"clean\""; theme = 1; next}
    {print}
    END {
      if (!theme) print "ZSH_THEME=\"clean\""
    }
  ' "$zshrc" >"$temporary"

  {
    printf '\n# >>> fedora-post-install zsh >>>\n'
    if ! grep -q 'oh-my-zsh\.sh' "$temporary"; then
      printf 'export ZSH="$HOME/.oh-my-zsh"\n'
      printf 'source "$ZSH/oh-my-zsh.sh"\n'
    fi
    printf '[[ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh\n'
    printf '[[ -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\n'
    printf '# <<< fedora-post-install zsh <<<\n'
  } >>"$temporary"

  chmod --reference="$zshrc" "$temporary"
  mv -f -- "$temporary" "$zshrc"
  log_ok "Configuration Zsh mise à jour ; sauvegarde initiale : $backup"
}

install_zsh_environment() {
  ensure_dnf_packages zsh zsh-autosuggestions zsh-syntax-highlighting curl git

  # Révision testée avec ce profil. Une installation existante est respectée ;
  # seules les nouvelles installations créées par le projet sont épinglées.
  local oh_my_zsh_commit="97b27bb2ec0701330b18c2d3e340b22e742b3fa8"
  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    run_cmd "Téléchargement de Oh My Zsh" git clone --filter=blob:none https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
    run_cmd "Épinglage de Oh My Zsh" git -C "$HOME/.oh-my-zsh" checkout --detach "$oh_my_zsh_commit"
    state_set oh_my_zsh_commit "$oh_my_zsh_commit"
  else
    [[ ! -L "$HOME/.oh-my-zsh" ]] || die "$HOME/.oh-my-zsh ne doit pas être un lien symbolique."
    local installed_commit
    installed_commit="$(git -C "$HOME/.oh-my-zsh" rev-parse HEAD 2>/dev/null || true)"
    log_ok "Oh My Zsh est déjà présent (révision ${installed_commit:-inconnue}) ; il n'est pas remplacé."
  fi

  configure_zsh_file

  local zsh_path current_shell
  zsh_path="$(command -v zsh)"
  current_shell="$(getent passwd "$(id -un)" | awk -F: '{print $7}')"
  if [[ "$current_shell" != "$zsh_path" ]] &&
    confirm_action safe "Définir Zsh comme shell par défaut ?"; then
    if is_true "$AUTO_CONFIRM_ALL_ACTIONS"; then
      run_cmd "Modification non interactive du shell par défaut" sudo usermod --shell "$zsh_path" "$(id -un)"
    else
      run_cmd "Modification du shell par défaut" chsh -s "$zsh_path"
    fi
  fi
}

install_fira_sans() {
  # La dernière release globale Mozilla (4.202) ne contient que Fira Sans
  # Condensed. La dernière version publiée de Fira Sans classique est 4.106.
  local version="4.106"
  local asset_url="https://github.com/mozilla/Fira/archive/refs/tags/${version}.zip"
  log_info "Fira Sans retenu : version $version, $asset_url"
  if is_true "$DRY_RUN"; then
    log_info "[dry-run] L'archive serait installée dans ~/.local/share/fonts/FiraSans."
    return 0
  fi

  ensure_dnf_packages unzip
  local archive="$RUNTIME_TMP/fira-sans.zip"
  local extract_dir="$RUNTIME_TMP/fira-sans"
  run_cmd "Téléchargement de Fira Sans" curl -fsSL "$asset_url" -o "$archive"
  state_set fira_sans_version "$version"
  state_set fira_sans_sha256 "$(sha256sum "$archive" | awk '{print $1}')"
  mkdir -p "$extract_dir"
  run_cmd "Extraction de Fira Sans" unzip -q "$archive" -d "$extract_dir"

  local destination="$HOME/.local/share/fonts/FiraSans"
  mkdir -p "$destination"
  mapfile -d '' font_files < <(find "$extract_dir" -type f \( -iname '*.otf' -o -iname '*.ttf' \) -print0)
  (("${#font_files[@]}" > 0)) || die "Aucune police Fira Sans trouvée dans l'archive."

  local font
  for font in "${font_files[@]}"; do
    install -m 0644 "$font" "$destination/$(basename "$font")"
  done
  run_cmd "Actualisation du cache des polices" fc-cache -f
  fc-match "Fira Sans" 2>&1 | tee -a "$LOG_FILE"
}

install_fonts() {
  ensure_dnf_packages fira-code-fonts rsms-inter-fonts fontconfig
  install_fira_sans
}

stage_desktop() {
  run_step_once desktop.gnome "Outils et extensions GNOME" install_gnome_tools
  run_step_once desktop.appimage "Prise en charge des AppImage" install_appimage_support
  run_if_enabled INSTALL_GEARLEVER desktop.gearlever "Gear Lever" install_gearlever
  run_step_once desktop.zsh "Zsh et Oh My Zsh" install_zsh_environment
  run_step_once desktop.fonts "Polices Fira Code, Fira Sans et Inter" install_fonts
}

install_brave() {
  if ! package_installed brave-browser; then
    ensure_dnf_packages dnf-plugins-core
    if [[ ! -f /etc/yum.repos.d/brave-browser.repo ]]; then
      run_cmd "Ajout du dépôt RPM officiel Brave" sudo dnf config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
    fi
    ensure_dnf_packages brave-browser
  fi
  if command -v xdg-settings >/dev/null 2>&1; then
    run_cmd "Définition de Brave comme navigateur par défaut" xdg-settings set default-web-browser brave-browser.desktop
  fi
}

install_bitwarden() { ensure_flatpak_app com.bitwarden.desktop; }
install_pinta() { ensure_dnf_packages pinta; }
install_upscayl() { ensure_flatpak_app org.upscayl.Upscayl; }
install_rustdesk() { ensure_flatpak_app com.rustdesk.RustDesk; }

install_mpv() {
  ensure_dnf_packages mpv
  if command -v xdg-mime >/dev/null 2>&1; then
    run_cmd "Association MPV avec video/mp4" xdg-mime default mpv.desktop video/mp4
    run_cmd "Association MPV avec Matroska" xdg-mime default mpv.desktop video/x-matroska
    run_cmd "Association MPV avec WebM" xdg-mime default mpv.desktop video/webm
  fi
}

install_clamav() {
  ensure_dnf_packages clamav clamav-freshclam
  run_cmd "Mise à jour initiale des signatures ClamAV" sudo freshclam
}

install_clamui() {
  if ! package_installed clamav; then
    install_clamav
  fi
  ensure_flatpak_app io.github.linx_systems.ClamUI
}

stage_apps() {
  run_if_enabled INSTALL_BRAVE apps.brave "Brave" install_brave
  run_if_enabled INSTALL_BITWARDEN apps.bitwarden "Bitwarden" install_bitwarden
  run_if_enabled INSTALL_PINTA apps.pinta "Pinta" install_pinta
  run_if_enabled INSTALL_UPSCAYL apps.upscayl "Upscayl" install_upscayl
  run_if_enabled INSTALL_MPV apps.mpv "MPV" install_mpv
  run_if_enabled INSTALL_RUSTDESK apps.rustdesk "RustDesk" install_rustdesk
  run_if_enabled INSTALL_CLAMAV apps.clamav "ClamAV" install_clamav
  run_if_enabled INSTALL_CLAMUI apps.clamui "ClamUI" install_clamui
}

collect_cleanup_packages() {
  local selected_name="$1"
  local flag_name="$2"
  local label="$3"
  shift 3
  local -n selected_ref="$selected_name"

  if [[ "${!flag_name}" != "true" ]]; then
    log_info "Conservé par $flag_name=false : $label"
    return 0
  fi

  log_warn "Suppression confirmée dans la configuration : $label"
  local package
  for package in "$@"; do
    if package_installed "$package"; then
      selected_ref["$package"]=1
      log_info "  Paquet installé sélectionné : $package"
    else
      log_info "  Déjà absent : $package"
    fi
  done
}

remove_preinstalled_fedora_apps() {
  local -A selected_packages=()
  local cleanup_requested=false

  local -a cleanup_flags=(
    SUPPRESSION_MEDIA_WRITER
    SUPPRESSION_CARTES
    SUPPRESSION_LIBREOFFICE
    SUPPRESSION_NUMERISEUR
    SUPPRESSION_MACHINES
    SUPPRESSION_CAMERA
    SUPPRESSION_CONNEXIONS
    SUPPRESSION_CONTROLE_PARENTAL
    SUPPRESSION_VISITE_GUIDEE
    SUPPRESSION_AIDE
  )
  local flag_name
  for flag_name in "${cleanup_flags[@]}"; do
    [[ "${!flag_name}" == "true" ]] && cleanup_requested=true
  done

  collect_cleanup_packages selected_packages SUPPRESSION_MEDIA_WRITER "Fedora Media Writer" mediawriter
  collect_cleanup_packages selected_packages SUPPRESSION_CARTES "Cartes" gnome-maps
  collect_cleanup_packages selected_packages SUPPRESSION_NUMERISEUR "Numériseur de documents" simple-scan
  collect_cleanup_packages selected_packages SUPPRESSION_MACHINES "Machines" gnome-boxes
  collect_cleanup_packages selected_packages SUPPRESSION_CAMERA "Caméra" snapshot cheese
  collect_cleanup_packages selected_packages SUPPRESSION_CONNEXIONS "Connexions" gnome-connections
  collect_cleanup_packages selected_packages SUPPRESSION_CONTROLE_PARENTAL "Contrôle parental" malcontent-control
  collect_cleanup_packages selected_packages SUPPRESSION_VISITE_GUIDEE "Visite guidée" gnome-tour
  collect_cleanup_packages selected_packages SUPPRESSION_AIDE "Aide GNOME" yelp

  if [[ "$SUPPRESSION_LIBREOFFICE" == "true" ]]; then
    log_warn "Suppression confirmée dans la configuration : LibreOffice"
    local libreoffice_package
    while IFS= read -r libreoffice_package; do
      [[ -n "$libreoffice_package" ]] || continue
      selected_packages["$libreoffice_package"]=1
      log_info "  Paquet LibreOffice installé sélectionné : $libreoffice_package"
    done < <(rpm -qa --qf '%{NAME}\n' 'libreoffice*' | sort -u)
  else
    log_info "Conservé par SUPPRESSION_LIBREOFFICE=false : LibreOffice"
  fi

  if [[ "$INSTALL_MPV" == "true" ]] && package_installed mpv; then
    cleanup_requested=true
    log_info "MPV est installé : suppression du lecteur vidéo Fedora de remplacement."
    local video_package
    for video_package in showtime totem; do
      package_installed "$video_package" && selected_packages["$video_package"]=1
    done
  else
    log_info "Lecteur vidéo Fedora conservé : MPV n'est pas sélectionné ou pas installé."
  fi

  if [[ "$INSTALL_BRAVE" == "true" ]] && package_installed brave-browser; then
    cleanup_requested=true
    log_info "Brave est installé : suppression de Firefox et de ses packs de langues."
    local firefox_package
    for firefox_package in firefox firefox-langpacks; do
      package_installed "$firefox_package" && selected_packages["$firefox_package"]=1
    done
  else
    log_info "Firefox conservé : Brave n'est pas sélectionné ou pas installé."
  fi

  local -a packages=()
  if ((${#selected_packages[@]} > 0)); then
    mapfile -t packages < <(printf '%s\n' "${!selected_packages[@]}" | sort)
    log_warn "Paquets préinstallés qui seront supprimés (${#packages[@]}) :"
    local selected_package
    for selected_package in "${packages[@]}"; do
      log_warn "  - $selected_package"
    done
    run_sensitive_dnf "Suppression des applications Fedora sélectionnées" remove "${packages[@]}"
  else
    log_ok "Aucune application préinstallée sélectionnée n'est encore présente."
  fi

  if [[ "$cleanup_requested" == "true" ]]; then
    log_warn "DNF va maintenant rechercher et supprimer les dépendances devenues inutiles."
    run_sensitive_dnf "Suppression des dépendances DNF inutilisées" autoremove
  else
    log_info "Nettoyage DNF ignoré : aucune suppression n'est demandée."
  fi
}

stage_cleanup() {
  run_step_once cleanup.preinstalled "Suppression des applications Fedora préinstallées" remove_preinstalled_fedora_apps
}

nvm_directory() {
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    printf '%s/nvm' "$XDG_CONFIG_HOME"
  else
    printf '%s/.nvm' "$HOME"
  fi
}

install_node_environment() {
  local nvm_version="v0.40.6"
  local nvm_dir
  nvm_dir="$(nvm_directory)"
  local installer="$RUNTIME_TMP/nvm-install.sh"

  if [[ ! -s "$nvm_dir/nvm.sh" ]]; then
    run_cmd "Téléchargement de NVM $nvm_version" curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_version}/install.sh" -o "$installer"
    if ! is_true "$DRY_RUN"; then
      state_set nvm_installer_sha256 "$(sha256sum "$installer" | awk '{print $1}')"
      run_cmd "Installation de NVM $nvm_version" env PROFILE="$HOME/.zshrc" bash "$installer"
    fi
  else
    log_ok "NVM est déjà installé dans $nvm_dir."
  fi

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Node.js 24 LTS et pnpm seraient installés avec NVM."
    return 0
  fi

  # shellcheck disable=SC1090
  source "$nvm_dir/nvm.sh"
  run_stateful_cmd "Installation du dernier correctif Node.js 24" nvm install 24
  run_stateful_cmd "Définition de Node.js 24 par défaut" nvm alias default 24
  run_stateful_cmd "Activation de Node.js 24" nvm use default
  hash -r
  run_cmd "Installation de la dernière version de pnpm" npm install --global pnpm@latest

  local node_version
  node_version="$(node --version)"
  [[ "$node_version" == v24.* ]] || die "Version Node.js inattendue : $node_version."
  state_set node_version "$node_version"
  state_set pnpm_version "$(pnpm --version)"
}

install_docker_engine() {
  local -a conflicting=(
    docker docker-client docker-client-latest docker-common docker-latest
    docker-latest-logrotate docker-logrotate docker-selinux
    docker-engine-selinux docker-engine podman-docker
  )
  local -a installed_conflicts=()
  local package
  for package in "${conflicting[@]}"; do
    package_installed "$package" && installed_conflicts+=("$package")
  done

  if (("${#installed_conflicts[@]}" > 0)); then
    confirm_action sensitive "Supprimer les paquets en conflit avec Docker Engine : ${installed_conflicts[*]} ?" ||
      die "Les conflits Docker doivent être résolus avant l'installation."
    run_sensitive_dnf "Suppression des conflits Docker" remove "${installed_conflicts[@]}"
  fi

  if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
    ensure_dnf_packages dnf-plugins-core
    run_cmd "Ajout du dépôt officiel Docker" sudo dnf config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo
  fi

  ensure_dnf_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_cmd "Activation du service Docker" sudo systemctl enable --now docker
  run_cmd "Test fonctionnel Docker hello-world" sudo docker run --rm hello-world
  run_cmd "Validation de Docker Compose" docker compose version

  local current_user
  current_user="$(id -un)"
  if ! id -nG "$current_user" | tr ' ' '\n' | grep -qx docker; then
    log_warn "Le groupe docker accorde des privilèges comparables à root."
    run_cmd "Ajout de $current_user au groupe docker" sudo usermod -aG docker "$current_user"
    state_set login_required true
  fi
}

install_vscode() {
  local repo_content
  repo_content="$(cat <<EOF
# $MANAGED_MARKER
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
)"

  if ! package_installed code; then
    run_cmd "Import de la clé Microsoft" sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    install_managed_content /etc/yum.repos.d/vscode.repo 0644 "$repo_content"$'\n'
    ensure_dnf_packages code
  fi
}

install_desktop_plus() { ensure_flatpak_app org.desktop_plus.desktop-plus; }
install_bruno() { ensure_flatpak_app com.usebruno.Bruno; }

install_rtk() {
  local installer="$RUNTIME_TMP/rtk-install.sh"
  run_cmd "Téléchargement de l'installateur RTK" curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh -o "$installer"
  if is_true "$DRY_RUN"; then
    return 0
  fi

  state_set rtk_installer_sha256 "$(sha256sum "$installer" | awk '{print $1}')"
  run_cmd "Installation de la dernière release RTK" sh "$installer"
  export PATH="$HOME/.local/bin:$PATH"
  require_command rtk
  record_installed_version rtk_version rtk --version
  run_cmd "Validation de l'installation RTK" rtk gain
}

install_cli_tools() {
  ensure_dnf_packages ripgrep fd-find fzf bat
  ensure_dnf_packages eza zoxide jq htop tree git-delta tokei
}

stage_development() {
  run_if_enabled INSTALL_NODE development.node "Node.js 24 LTS, NVM et pnpm" install_node_environment
  run_if_enabled INSTALL_DOCKER development.docker "Docker Engine" install_docker_engine
  run_if_enabled INSTALL_VSCODE development.vscode "Visual Studio Code" install_vscode
  run_if_enabled INSTALL_DESKTOP_PLUS development.desktop-plus "Desktop Plus" install_desktop_plus
  run_if_enabled INSTALL_BRUNO development.bruno "Bruno" install_bruno
  run_if_enabled INSTALL_RTK development.rtk "RTK" install_rtk
  run_if_enabled INSTALL_CLI_TOOLS development.cli "Outils en ligne de commande" install_cli_tools
}

install_steam() {
  enable_rpmfusion
  ensure_dnf_packages steam
}
install_bottles() { ensure_flatpak_app com.usebottles.bottles; }
install_lutris() { ensure_dnf_packages lutris; }
install_heroic() { ensure_flatpak_app com.heroicgameslauncher.hgl; }
install_gamemode() { ensure_dnf_packages gamemode gamemode.i686; }
install_gamescope() { ensure_dnf_packages gamescope; }

stage_gaming() {
  run_if_enabled INSTALL_STEAM gaming.steam "Steam" install_steam
  run_if_enabled INSTALL_BOTTLES gaming.bottles "Bottles" install_bottles
  run_if_enabled INSTALL_LUTRIS gaming.lutris "Lutris" install_lutris
  run_if_enabled INSTALL_HEROIC gaming.heroic "Heroic Games Launcher" install_heroic
  run_if_enabled INSTALL_GAMEMODE gaming.gamemode "GameMode" install_gamemode
  run_if_enabled INSTALL_GAMESCOPE gaming.gamescope "Gamescope" install_gamescope
}

validate_flatpak_if_enabled() {
  local flag_name="$1"
  local application_id="$2"
  [[ "${!flag_name}" == "true" ]] || return 0
  if flatpak info --system "$application_id" >>"$LOG_FILE" 2>&1; then
    log_ok "Flatpak validé : $application_id"
  else
    die "Flatpak sélectionné mais absent : $application_id"
  fi
}

validate_rpm_if_enabled() {
  local flag_name="$1"
  local package="$2"
  [[ "${!flag_name}" == "true" ]] || return 0
  package_installed "$package" || die "Paquet sélectionné mais absent : $package"
  log_ok "Paquet validé : $package"
}

stage_validation() {
  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Les validations finales seraient exécutées après installation."
    return 0
  fi

  run_cmd "Validation finale DNF" sudo dnf check
  if dnf repolist --enabled 2>/dev/null | grep -qi rawhide; then
    die "Validation refusée : un dépôt Rawhide est actif."
  fi

  validate_rpm_if_enabled INSTALL_BRAVE brave-browser
  validate_rpm_if_enabled INSTALL_PINTA pinta
  validate_rpm_if_enabled INSTALL_MPV mpv
  validate_rpm_if_enabled INSTALL_CLAMAV clamav
  validate_flatpak_if_enabled INSTALL_BITWARDEN com.bitwarden.desktop
  validate_flatpak_if_enabled INSTALL_UPSCAYL org.upscayl.Upscayl
  validate_flatpak_if_enabled INSTALL_RUSTDESK com.rustdesk.RustDesk
  validate_flatpak_if_enabled INSTALL_CLAMUI io.github.linx_systems.ClamUI
  validate_flatpak_if_enabled INSTALL_GEARLEVER it.mijorus.gearlever
  validate_flatpak_if_enabled INSTALL_DESKTOP_PLUS org.desktop_plus.desktop-plus
  validate_flatpak_if_enabled INSTALL_BRUNO com.usebruno.Bruno
  validate_flatpak_if_enabled INSTALL_BOTTLES com.usebottles.bottles
  validate_flatpak_if_enabled INSTALL_HEROIC com.heroicgameslauncher.hgl
  validate_rpm_if_enabled INSTALL_STEAM steam
  validate_rpm_if_enabled INSTALL_LUTRIS lutris
  validate_rpm_if_enabled INSTALL_GAMEMODE gamemode
  validate_rpm_if_enabled INSTALL_GAMESCOPE gamescope

  if [[ "$INSTALL_NODE" == "true" ]]; then
    local nvm_dir
    nvm_dir="$(nvm_directory)"
    # shellcheck disable=SC1090
    source "$nvm_dir/nvm.sh"
    [[ "$(node --version)" == v24.* ]] || die "Node.js 24 n'est pas actif."
    pnpm --version 2>&1 | tee -a "$LOG_FILE"
  fi
  if [[ "$INSTALL_DOCKER" == "true" ]]; then
    run_cmd "Nouvelle validation Docker hello-world" sudo docker run --rm hello-world
    run_cmd "Nouvelle validation Docker Compose" docker compose version
  fi
  if [[ "$INSTALL_RTK" == "true" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
    run_cmd "Nouvelle validation RTK" rtk gain
  fi

  if [[ "$INSTALL_HARDWARE_CODECS" == "true" ]]; then
    command -v vainfo >/dev/null 2>&1 && vainfo 2>&1 | tee -a "$LOG_FILE" || true
    command -v vulkaninfo >/dev/null 2>&1 &&
      vulkaninfo --summary 2>&1 | tee -a "$LOG_FILE" || true
  fi
  if [[ "$HAS_NVIDIA_GPU" == "true" && "$NVIDIA_DRIVER" == "auto" ]]; then
    run_cmd "Validation NVIDIA" nvidia-smi
  fi

  fc-match "Fira Code" 2>&1 | tee -a "$LOG_FILE"
  fc-match "Fira Sans" 2>&1 | tee -a "$LOG_FILE"
  fc-match "Inter" 2>&1 | tee -a "$LOG_FILE"

  log_ok "Toutes les validations bloquantes ont réussi."
  if [[ "$(state_get login_required false)" == "true" ]]; then
    log_warn "Une nouvelle connexion est nécessaire pour utiliser Docker sans sudo."
  fi
  if [[ "$(state_get logout_required false)" == "true" ]]; then
    log_warn "Déconnectez-vous puis reconnectez-vous pour charger complètement le profil GNOME et ses extensions."
  fi
}

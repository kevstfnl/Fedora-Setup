#!/usr/bin/env bash

# Parcours CachyOS à checkpoints multiples. Les redémarrages sont volontairement
# manuels afin que l'utilisateur sélectionne explicitement CachyOS dans GRUB.

readonly CACHYOS_COPR="bieszczaders/kernel-cachyos"
readonly CACHYOS_ADDONS_COPR="bieszczaders/kernel-cachyos-addons"
readonly CACHYOS_KEY_FINGERPRINT="537DEED33436B0367F5B26D5B3E3132CF10859CF"
readonly CACHYOS_HELPER_TARGET="/usr/local/libexec/fedora-post-install/select-cachy-kernel"
readonly CACHYOS_ACTION_TARGET="/etc/dnf/libdnf5-plugins/actions.d/cachy-default.actions"

save_state_once() {
  local key="$1"
  local value="$2"
  [[ -n "$(state_get "$key")" ]] || state_set "$key" "$value"
}

verify_cachyos_copr_key() {
  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Empreinte COPR attendue : $CACHYOS_KEY_FINGERPRINT"
    return 0
  fi

  require_command gpg
  local key_file="$RUNTIME_TMP/cachyos-copr-key.gpg"
  local gpg_home="$RUNTIME_TMP/gnupg"
  mkdir -m 0700 "$gpg_home"
  run_cmd "Téléchargement de la clé publique COPR CachyOS" curl -fsSL https://download.copr.fedorainfracloud.org/results/bieszczaders/kernel-cachyos/pubkey.gpg -o "$key_file"

  local fingerprint
  fingerprint="$(GNUPGHOME="$gpg_home" gpg --batch --show-keys --with-colons "$key_file" 2>>"$LOG_FILE" |
    awk -F: '$1 == "fpr" {print toupper($10); exit}')"
  [[ "$fingerprint" == "$CACHYOS_KEY_FINGERPRINT" ]] ||
    die "Empreinte COPR inattendue : ${fingerprint:-absente}."
  log_ok "Empreinte COPR CachyOS validée : $fingerprint"
}

cachyos_preflight() {
  log_warn "CachyOS est un noyau tiers expérimental, recommandé ici uniquement pour un PC de test."
  require_command grubby
  require_command mokutil
  require_command getsebool

  [[ "$(uname -m)" == "x86_64" ]] || die "CachyOS Workstation exige x86_64."
  /lib64/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v3.*supported, searched' ||
    die "Le processeur ne prend pas en charge x86-64-v3."
  log_ok "Compatibilité x86-64-v3 validée."

  local boot_available_kib
  boot_available_kib="$(df -Pk /boot | awk 'NR == 2 {print $4}')"
  [[ "$boot_available_kib" =~ ^[0-9]+$ ]] || die "Espace /boot impossible à mesurer."
  ((boot_available_kib >= 512 * 1024)) ||
    die "Moins de 512 Mio sont disponibles dans /boot."
  log_info "Espace disponible dans /boot : $((boot_available_kib / 1024)) Mio."

  local fedora_kernel
  fedora_kernel="$(latest_fedora_kernel)"
  validate_kernel_path "$fedora_kernel" ||
    die "Aucun noyau Fedora amorçable n'a été trouvé."
  save_state_once cachyos_fedora_kernel_before "$fedora_kernel"
  log_info "Noyau Fedora de secours : $fedora_kernel"

  local grub_default
  grub_default="$(grep -m1 '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null || true)"
  save_state_once cachyos_grub_default_before "${grub_default:-__missing__}"

  local selinux_value
  selinux_value="$(getsebool domain_kernel_load_modules 2>/dev/null | awk '{print $NF}')"
  [[ "$selinux_value" == "on" || "$selinux_value" == "off" ]] ||
    die "État SELinux domain_kernel_load_modules indéterminé."
  save_state_once cachyos_selinux_before "$selinux_value"

  local secure_boot_output
  secure_boot_output="$(mokutil --sb-state 2>&1 || true)"
  if grep -qi enabled <<<"$secure_boot_output"; then
    die "Secure Boot est actif. Désactivez-le manuellement dans l'UEFI puis relancez avec --resume."
  fi
  grep -qi disabled <<<"$secure_boot_output" ||
    die "L'état de Secure Boot est indéterminé : $secure_boot_output"
  log_ok "Secure Boot est désactivé."

  if [[ "$HAS_NVIDIA_GPU" == "true" ]]; then
    local nvidia_akmod=false package
    for package in akmod-nvidia akmod-nvidia-580xx akmod-nvidia-470xx akmod-nvidia-390xx; do
      package_installed "$package" && nvidia_akmod=true
    done
    [[ "$nvidia_akmod" == "true" ]] ||
      die "GPU NVIDIA détecté sans paquet akmod RPM Fusion compatible."
  fi

  verify_cachyos_copr_key
}

enable_cachyos_copr() {
  ensure_dnf_packages dnf-plugins-core
  if dnf repolist --all 2>/dev/null | grep -q 'copr:copr.fedorainfracloud.org:bieszczaders:kernel-cachyos'; then
    log_ok "COPR CachyOS déjà configuré."
  else
    run_cmd "Activation du COPR CachyOS GCC" sudo dnf copr enable "$CACHYOS_COPR"
  fi
}

validate_cachyos_kernel_package() {
  local boot_kernel="$1"
  local kernel_version="${boot_kernel#/boot/vmlinuz-}"
  local packaged_kernel="/usr/lib/modules/$kernel_version/vmlinuz"
  local package_owner

  [[ -f "$packaged_kernel" && ! -L "$packaged_kernel" ]] ||
    die "Le noyau CachyOS installé est absent de $packaged_kernel."
  package_owner="$(rpm -qf "$packaged_kernel" 2>/dev/null || true)"
  [[ "$package_owner" == kernel-cachyos-core-* ]] ||
    die "Propriétaire inattendu du noyau CachyOS : ${package_owner:-aucun}."
  log_ok "Paquet du noyau CachyOS validé : $package_owner"
}

install_cachyos_kernel() {
  enable_cachyos_copr
  ensure_dnf_packages kernel-cachyos kernel-cachyos-devel-matched

  if is_true "$DRY_RUN"; then
    log_info "[dry-run] Le noyau Fedora courant resterait le choix par défaut."
    return 0
  fi

  local cachy_kernel
  cachy_kernel="$(latest_cachy_kernel)"
  validate_kernel_path "$cachy_kernel" ||
    die "Le paquet a été installé, mais aucun noyau CachyOS valide n'est visible dans /boot."
  state_set cachyos_installed_kernel "$cachy_kernel"
  # /boot/vmlinuz-* peut être créé par kernel-install et ne pas appartenir
  # directement au RPM. Vérifier la copie canonique livrée dans /usr/lib.
  validate_cachyos_kernel_package "$cachy_kernel"

  if [[ "$(state_get cachyos_selinux_before)" == "off" ]]; then
    run_cmd "Autorisation SELinux du chargement des modules" sudo setsebool -P domain_kernel_load_modules on
    state_set cachyos_selinux_changed true
  fi

  if [[ "$HAS_NVIDIA_GPU" == "true" ]]; then
    local kernel_version="${cachy_kernel#/boot/vmlinuz-}"
    run_cmd "Compilation NVIDIA pour $kernel_version" sudo akmods --force --kernels "$kernel_version"
    modinfo -k "$kernel_version" -F version nvidia 2>&1 | tee -a "$LOG_FILE"
  fi

  local fedora_kernel
  fedora_kernel="$(state_get cachyos_fedora_kernel_before)"
  validate_kernel_path "$fedora_kernel" ||
    die "Le noyau Fedora de secours enregistré n'est plus valide : $fedora_kernel"
  run_cmd "Conservation de Fedora comme noyau par défaut avant le test" sudo grubby --set-default "$fedora_kernel"
}

validate_cachyos_boot() {
  local running_kernel
  running_kernel="$(uname -r)"
  [[ "${running_kernel,,}" == *cachy* ]] ||
    die "Le système ne tourne pas sur CachyOS ($running_kernel). Sélectionnez-le dans GRUB puis relancez avec --resume."

  local kernel_file="/boot/vmlinuz-$running_kernel"
  validate_kernel_path "$kernel_file" || die "Fichier du noyau courant invalide : $kernel_file"
  validate_cachyos_kernel_package "$kernel_file"

  local fedora_kernel
  fedora_kernel="$(latest_fedora_kernel)"
  validate_kernel_path "$fedora_kernel" || die "Le noyau Fedora de secours a disparu."

  local failed_units
  failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null || true)"
  if [[ -n "$failed_units" ]]; then
    log_warn "Unités systemd en échec après démarrage CachyOS :"
    while IFS= read -r unit; do log_warn "  $unit"; done <<<"$failed_units"
    confirm_action sensitive "Continuer malgré ces unités en échec ?" ||
      die "Validation CachyOS interrompue."
  fi

  if [[ "$HAS_NVIDIA_GPU" == "true" ]]; then
    run_cmd "Validation NVIDIA sur CachyOS" nvidia-smi
    lsmod | grep -q '^nvidia' || die "Le module NVIDIA n'est pas chargé."
  fi
  command -v vulkaninfo >/dev/null 2>&1 &&
    vulkaninfo --summary 2>&1 | tee -a "$LOG_FILE" || true
  log_ok "Premier démarrage CachyOS validé : $running_kernel"
}

capture_addons_state() {
  local ananicy_enabled="disabled"
  local ananicy_active="inactive"
  systemctl is-enabled --quiet ananicy-cpp 2>/dev/null && ananicy_enabled="enabled"
  systemctl is-active --quiet ananicy-cpp 2>/dev/null && ananicy_active="active"

  save_state_once cachyos_zram_defaults_before "$(package_installed zram-generator-defaults && printf true || printf false)"
  save_state_once cachyos_settings_before "$(package_installed cachyos-settings && printf true || printf false)"
  save_state_once cachyos_ananicy_installed_before "$(package_installed ananicy-cpp && printf true || printf false)"
  save_state_once cachyos_ananicy_enabled_before "$ananicy_enabled"
  save_state_once cachyos_ananicy_active_before "$ananicy_active"

  if command -v zramctl >/dev/null 2>&1; then
    local zram_summary
    zram_summary="$(zramctl --noheadings --output NAME,ALGORITHM,DISKSIZE 2>/dev/null |
      tr '\n' ';' | sed 's/;$//')"
    save_state_once cachyos_zram_summary_before "${zram_summary:-none}"
  fi
}

install_cachyos_addons() {
  capture_addons_state
  ensure_dnf_packages dnf-plugins-core
  run_cmd "Activation du COPR des addons CachyOS" sudo dnf copr enable "$CACHYOS_ADDONS_COPR"

  local -a addon_packages=(cachyos-settings scx-scheds scx-tools scx-manager ananicy-cpp)
  local -a added_packages=()
  local package
  for package in "${addon_packages[@]}"; do
    package_installed "$package" || added_packages+=("$package")
  done
  local added_packages_value=""
  if (("${#added_packages[@]}" > 0)); then
    printf -v added_packages_value '%s ' "${added_packages[@]}"
    added_packages_value="${added_packages_value% }"
  fi
  state_set cachyos_added_addon_packages "$added_packages_value"

  if package_installed zram-generator-defaults; then
    confirm_action sensitive "Remplacer la configuration ZRAM Fedora par cachyos-settings ?" ||
      die "Le remplacement ZRAM a été refusé."
    run_cmd "Remplacement de la configuration ZRAM" sudo dnf swap zram-generator-defaults cachyos-settings
    state_set cachyos_zram_swapped true
  else
    ensure_dnf_packages cachyos-settings
  fi

  run_cmd "Régénération de l'initramfs après réglages CachyOS" sudo dracut -f
  ensure_dnf_packages scx-scheds scx-tools scx-manager
  ensure_dnf_packages ananicy-cpp
  run_cmd "Activation du service Ananicy" sudo systemctl enable --now ananicy-cpp
}

validate_cachyos_addons_boot() {
  local running_kernel="$(uname -r)"
  [[ "${running_kernel,,}" == *cachy* ]] ||
    die "Sélectionnez à nouveau CachyOS dans GRUB pour valider les addons."

  package_installed cachyos-settings || die "cachyos-settings est absent."
  ! package_installed zram-generator-defaults ||
    die "zram-generator-defaults est toujours installé après le swap."

  local package
  for package in scx-scheds scx-tools scx-manager ananicy-cpp; do
    package_installed "$package" || die "Addon CachyOS absent : $package"
  done
  systemctl is-enabled --quiet ananicy-cpp || die "ananicy-cpp n'est pas activé."
  systemctl is-active --quiet ananicy-cpp || die "ananicy-cpp n'est pas actif."
  zramctl 2>&1 | tee -a "$LOG_FILE"
  log_ok "Addons CachyOS et ZRAM validés."
}

ensure_grub_saved_mode() {
  local current_line
  current_line="$(grep -m1 '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null || true)"
  [[ "$current_line" == "GRUB_DEFAULT=saved" ]] && return 0

  local temporary="$RUNTIME_TMP/grub-default"
  awk '
    BEGIN {done = 0}
    /^GRUB_DEFAULT=/ && !done {print "GRUB_DEFAULT=saved"; done = 1; next}
    {print}
    END {if (!done) print "GRUB_DEFAULT=saved"}
  ' /etc/default/grub >"$temporary"
  run_cmd "Configuration de GRUB_DEFAULT=saved" sudo install -o root -g root -m 0644 "$temporary" /etc/default/grub
  state_set cachyos_grub_default_changed true
}

install_cachyos_default_hook() {
  ensure_dnf_packages libdnf5-plugin-actions
  ensure_grub_saved_mode

  local helper_source="$SCRIPT_DIR/scripts/select-cachy-kernel.sh"
  [[ -f "$helper_source" && ! -L "$helper_source" ]] ||
    die "Helper CachyOS manquant : $helper_source"
  run_cmd "Installation du helper CachyOS géré" sudo install -D -o root -g root -m 0755 "$helper_source" "$CACHYOS_HELPER_TARGET"

  local action_content
  action_content="$(cat <<EOF
# $MANAGED_MARKER
# Après une transaction kernel*, sélectionner le dernier noyau CachyOS valide.
post_transaction:kernel*:in::$CACHYOS_HELPER_TARGET
EOF
)"
  install_managed_content "$CACHYOS_ACTION_TARGET" 0644 "$action_content"$'\n'

  if ! is_true "$DRY_RUN"; then
    run_cmd "Sélection du dernier noyau CachyOS" sudo "$CACHYOS_HELPER_TARGET"
    local selected
    selected="$(sudo grubby --default-kernel)"
    [[ "${selected,,}" == *cachy* ]] ||
      die "Le noyau par défaut n'est pas CachyOS après installation du helper : $selected"
    state_set cachyos_default_kernel "$selected"
  fi
}

stage_cachyos() {
  if [[ "$INSTALL_CACHYOS" != "true" ]]; then
    log_info "INSTALL_CACHYOS=false : aucun dépôt, noyau ou addon CachyOS ne sera modifié."
    return 0
  fi

  if is_true "$DRY_RUN"; then
    log_step "CachyOS — Simulation complète"
    cachyos_preflight
    install_cachyos_kernel
    log_info "[dry-run] Un premier démarrage manuel sur CachyOS serait requis."
    if [[ "$INSTALL_CACHYOS_ADDONS" == "true" ]]; then
      install_cachyos_addons
      log_info "[dry-run] Un second démarrage manuel validerait ZRAM et les addons."
    fi
    install_cachyos_default_hook
    return 0
  fi

  if ! state_step_done cachyos.preflight; then
    log_step "CachyOS — Prévalidation"
    cachyos_preflight
    state_mark_step cachyos.preflight
  fi

  if ! state_step_done cachyos.kernel-installed; then
    log_step "CachyOS — Installation du noyau GCC"
    install_cachyos_kernel
    state_mark_step cachyos.kernel-installed
    request_manual_reboot cachyos-kernel "Sélectionnez manuellement le noyau CachyOS dans GRUB pour effectuer le premier test."
  fi

  if ! state_step_done cachyos.kernel-boot-validated; then
    log_step "CachyOS — Validation du premier démarrage"
    validate_cachyos_boot
    state_mark_step cachyos.kernel-boot-validated
    state_set resume_required ""
  fi

  if [[ "$INSTALL_CACHYOS_ADDONS" == "true" ]]; then
    if ! state_step_done cachyos.addons-installed; then
      log_step "CachyOS — Installation des addons"
      install_cachyos_addons
      state_mark_step cachyos.addons-installed
      request_manual_reboot cachyos-addons "Redémarrez et sélectionnez à nouveau CachyOS pour valider ZRAM et les addons."
    fi

    if ! state_step_done cachyos.addons-boot-validated; then
      log_step "CachyOS — Validation des addons"
      validate_cachyos_addons_boot
      state_mark_step cachyos.addons-boot-validated
      state_set resume_required ""
    fi
  else
    log_info "INSTALL_CACHYOS_ADDONS=false : addons ignorés."
  fi

  run_step_once cachyos.default-hook "Maintien sûr de CachyOS comme noyau par défaut" install_cachyos_default_hook
  state_set cachyos_complete true
}

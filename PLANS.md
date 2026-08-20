# Post-installation de Fedora Workstation 44 (GNOME)

Ce projet fournit un script Bash de post-installation **personnel**, **défensif**, **rejouable** et destiné à **Fedora Workstation 44 avec GNOME**. Les informations techniques ont été vérifiées le **20 août 2026**.

La procédure cible l'édition RPM classique de Fedora sur `x86_64`. Elle ne doit pas être exécutée sur Fedora Silverblue, Kinoite ou une autre édition Atomic.

> [!WARNING]
> Le script modifie des dépôts, des pilotes et, sur demande seulement, le noyau. Il conserve un noyau Fedora amorçable, refuse une exécution en tant que `root` et demande une confirmation avant toute opération sensible.

## Démarrage rapide

1. Relire et adapter les valeurs commentées dans [`config.ini`](config.ini).
2. Valider la syntaxe de la configuration :

   ```bash
   ./fedora-setup.sh --validate-config
   ```

3. Examiner le plan complet sans modifier le système :

   ```bash
   ./fedora-setup.sh --dry-run
   ```

4. Lancer l'installation depuis une session GNOME normale, sans préfixer la commande par `sudo` :

   ```bash
   ./fedora-setup.sh
   ```

Après une interruption ou le redémarrage demandé par le parcours CachyOS, reprendre avec :

```bash
./fedora-setup.sh --resume
```

Les options `--only ETAPE`, `--skip ETAPE` et `--set CLE=VALEUR` permettent un lancement ciblé. `./fedora-setup.sh --help` donne la liste exacte des étapes et des options.

Le journal principal et l'état de reprise sont conservés dans `${XDG_STATE_HOME:-$HOME/.local/state}/fedora-post-install`. La configuration ne contient aucun secret et le journal évite volontairement d'enregistrer des données sensibles.

### Organisation du projet

```text
fedora-setup.sh                  point d'entrée et orchestration
config.ini                      choix utilisateur commentés
lib/common.sh                   logs, état, confirmations et garde-fous
lib/config.sh                   parseur INI strict
lib/tasks.sh                    étapes Fedora, applications et validations
lib/cachyos.sh                  installation et validation CachyOS
scripts/select-cachy-kernel.sh  helper géré pour le noyau par défaut
scripts/uninstall-cachyos.sh    retour autonome et prudent vers Fedora
tests/run.sh                    tests statiques et du parseur
```

La désinstallation CachyOS peut elle aussi être simulée avant exécution :

```bash
./scripts/uninstall-cachyos.sh --dry-run
./scripts/uninstall-cachyos.sh
```

## Contrat d'exécution

Avant toute modification, le script devra vérifier :

- `ID=fedora`, `VERSION_ID=44` et l'édition Workstation ;
- que le système n'est pas géré par `rpm-ostree` ;
- l'architecture, la session GNOME, la connectivité et l'espace disque ;
- l'accès à `sudo`, sans lancer tout le script avec `sudo` ;
- le ou les GPU présents, y compris les configurations hybrides ;
- l'état de Secure Boot avec `mokutil --sb-state` ;
- le système de fichiers et les options de montage ;
- la présence d'une exécution interrompue.

L'exécution devra également respecter les règles suivantes :

- mode Bash strict, verrou exclusif et gestion propre de `INT`/`TERM` ;
- journal sans secret dans `${XDG_STATE_HOME:-$HOME/.local/state}/fedora-post-install/run.log` ;
- état écrit atomiquement après chaque opération réussie ;
- reprise avec `--resume`, aperçu avec `--dry-run` et aide avec `--help` ;
- prévalidation de chaque dépôt et paquet avant installation ;
- absence de `-y` pour les opérations sensibles ;
- aucune suppression d'application ou modification du démarrage sans confirmation ;
- résolution des versions « latest » une seule fois par exécution, puis enregistrement dans l'état pour garantir une reprise cohérente.

Un redémarrage automatique n'est autorisé que par `AUTO_REBOOT=true`. Le script sauvegarde d'abord sa progression et permet toujours de reprendre avec `--resume`.

## Configuration

Le fichier [`config.ini`](config.ini) constitue la source principale des choix utilisateur. Le lancement standard sera :

```bash
./fedora-setup.sh --config ./config.ini
```

Le parseur devra lire le fichier comme des données et ne jamais l'exécuter avec `source`. Il ignorera les lignes vides et les commentaires, supprimera les espaces autour des clés et valeurs, puis refusera :

- une clé inconnue ou dupliquée ;
- une valeur vide hors cas explicitement permis ;
- une valeur booléenne différente de `true` ou `false` ;
- une version de schéma différente de `CONFIG_VERSION=1`.

Les options CLI auront priorité sur le fichier : valeurs internes par défaut, puis `config.ini`, puis arguments CLI. Le script affichera le plan résolu avant toute modification.

`AUTO_CONFIRM_SAFE_ACTIONS=true` autorise les installations ordinaires sélectionnées dans la configuration et transmet `--assumeyes` aux transactions DNF/Flatpak correspondantes. Cela ne contourne jamais les contrôles matériels, la vérification des dépôts, les transactions destructrices ou les étapes de récupération.

`AUTO_CONFIRM_ALL_ACTIONS=true` étend cette automatisation aux confirmations sensibles ainsi qu'aux transactions DNF correspondantes, notamment l'activation des COPR, les swaps et les suppressions nécessaires. Ce mode ne contourne jamais l'authentification `sudo`, Secure Boot, les erreurs matérielles ou les deux démarrages manuels de validation CachyOS. `AUTO_REBOOT` reste la seule option autorisant un redémarrage automatique hors du parcours CachyOS.

`AUTO_REBOOT=true` autorise un redémarrage automatique après sauvegarde de l'état. Pour le redémarrage final, l'identifiant du démarrage courant est enregistré puis comparé au lancement suivant afin d'acquitter la recommandation et d'éviter une boucle. Il est volontairement ignoré lors du premier démarrage CachyOS, qui exige une sélection manuelle dans GRUB.

Les dépendances implicites sont limitées et documentées :

- `INSTALL_CLAMUI=true` installe aussi le moteur ClamAV nécessaire sur l'hôte ;
- `INSTALL_DOCKER=true` installe et démarre Docker, valide `hello-world`, puis ajoute l'utilisateur au groupe `docker` ;
- `INSTALL_NODE=true` installe Node.js 24 LTS via NVM ainsi que pnpm ;
- `INSTALL_CACHYOS=true` active uniquement le parcours expérimental détaillé ci-dessous ;
- `INSTALL_CACHYOS_ADDONS=true` ajoute les réglages, ordonnanceurs et services CachyOS uniquement si le noyau CachyOS est lui-même activé ;
- `HIDE_GRUB_AFTER_CACHYOS=true` réactive le masquage conditionnel Fedora seulement après les validations CachyOS ;
- `NVIDIA_DRIVER=auto` sélectionne la branche RPM Fusion compatible ou ne fait rien en l'absence de GPU NVIDIA.

`NVIDIA_DRIVER` accepte uniquement `auto` ou `disabled`. La valeur `disabled` interdit l'installation d'un pilote propriétaire, mais déclenche un avertissement si un GPU NVIDIA est détecté.

Le fichier ne doit contenir aucun secret. Aucun outil d'IA n'est installé ou configuré par ce projet.

## Déroulement

### Étape 1 — Préparation et mise à jour

- créer le verrou, le journal et le fichier d'état ;
- effectuer les contrôles de compatibilité ;
- proposer la définition du nom d'hôte ;
- ajouter uniquement le réglage DNF documenté ci-dessous ;
- auditer Btrfs sans modifier ses options par défaut ;
- exécuter `sudo dnf upgrade --refresh`, puis `sudo dnf check` ;
- utiliser `dnf needs-restarting` pour signaler un éventuel redémarrage ;
- sauvegarder la progression.

Fedora active déjà la compression Btrfs `zstd:1` par défaut. Le script ne doit donc pas réécrire `/etc/fstab`, changer la compression, activer `noatime` ou lancer une recompression sans option dédiée et confirmation explicite.

### Étape 2 — Dépôts, codecs et pilotes

- proposer les dépôts tiers Fedora et RPM Fusion séparément ;
- ajouter Flathub avec une portée système cohérente ;
- installer les [codecs multimédias](#codecs-multimédias) si `INSTALL_HARDWARE_CODECS=true` ;
- configurer l'[accélération matérielle](#accélération-matérielle) selon chaque GPU détecté ;
- traiter [NVIDIA](#nvidia) séparément, notamment lorsque Secure Boot est actif ;
- sauvegarder la progression et proposer un redémarrage si nécessaire.

### Étape 3 — GNOME, shell et polices

- installer les [outils GNOME](#outils-gnome) disponibles pour la version courante ;
- installer Zsh et Oh My Zsh avec le thème `clean` ;
- activer `zsh-autosuggestions` et `zsh-syntax-highlighting`, ce dernier étant chargé en dernier ;
- ajouter la [prise en charge des AppImage](#appimage) ;
- installer Fira Code, Fira Sans et Inter ;
- ne modifier le shell par défaut qu'après confirmation.

### Étape 4 — Applications personnelles

| Option | Application | Source prévue | Identifiant ou paquet |
| --- | --- | --- | --- |
| `INSTALL_MPV` | MPV | Fedora | `mpv` |
| `INSTALL_BRAVE` | Brave | dépôt RPM officiel Brave | `brave-browser` |
| `INSTALL_BITWARDEN` | Bitwarden | Flathub officiel | `com.bitwarden.desktop` |
| `INSTALL_PINTA` | Pinta | Fedora | `pinta` |
| `INSTALL_UPSCAYL` | Upscayl | Flathub | `org.upscayl.Upscayl` |
| `INSTALL_RUSTDESK` | RustDesk | Flathub | `com.rustdesk.RustDesk` |
| `INSTALL_CLAMAV` | ClamAV | Fedora | `clamav clamav-freshclam` |
| `INSTALL_CLAMUI` | ClamUI | Flathub | `io.github.linx_systems.ClamUI` et moteur ClamAV sur l'hôte |
| `INSTALL_GEARLEVER` | Gear Lever | Flathub | `it.mijorus.gearlever` |

MPV pourra être associé aux principaux types MIME vidéo et Brave défini comme navigateur par défaut. Le lecteur vidéo Fedora ne sera supprimé que si MPV est installé avec succès ; Firefox suit la même règle avec Brave.

> [!IMPORTANT]
> Bitwarden Desktop ne remplace pas le trousseau GNOME utilisé par le système et les applications. Le script ne doit pas supprimer `gnome-keyring`.

### Étape 5 — Environnement de travail

- `INSTALL_NODE` : [Node.js 24 LTS avec NVM et pnpm](#nodejs-avec-nvm) ;
- `INSTALL_DOCKER` : [Docker Engine](#docker) ;
- `INSTALL_VSCODE` : Visual Studio Code depuis le dépôt RPM officiel Microsoft ;
- `INSTALL_BRUNO` : Bruno via Flathub (`com.usebruno.Bruno`) ;
- `INSTALL_DESKTOP_PLUS` : Desktop Plus via Flathub (`org.desktop_plus.desktop-plus`) ;
- `INSTALL_RTK` : [RTK](#rtk) dans sa dernière version installable ;
- `INSTALL_CLI_TOOLS` : les [outils en ligne de commande](#outils-en-ligne-de-commande).

Desktop Plus est le fork communautaire Linux de GitHub Desktop maintenu par Pol Rivero, et non une application officielle GitHub. La version Flatpak est volontairement retenue :

```bash
flatpak install --system flathub org.desktop_plus.desktop-plus
```

Les hooks Git lancés depuis cette application sont soumis au bac à sable Flatpak et peuvent ne pas voir les outils installés sur l'hôte, notamment NVM ou certains linters.

### Étape 6 — Jeux

Chaque élément est indépendant et contrôlé par sa clé `INSTALL_*` :

| Option | Source | Paquet ou identifiant |
| --- | --- | --- |
| `INSTALL_STEAM` | RPM Fusion Nonfree | `steam` |
| `INSTALL_BOTTLES` | Flathub | `com.usebottles.bottles` |
| `INSTALL_LUTRIS` | Fedora | `lutris` |
| `INSTALL_HEROIC` | Flathub | `com.heroicgameslauncher.hgl` |
| `INSTALL_GAMEMODE` | Fedora | `gamemode` et prise en charge 32 bits |
| `INSTALL_GAMESCOPE` | Fedora | `gamescope` |

Steam nécessite RPM Fusion Nonfree. Les applications Flatpak utilisent leurs propres runtimes : Heroic devra utiliser son gestionnaire Wine/Proton intégré lorsqu'un binaire installé sur l'hôte n'est pas visible depuis le bac à sable.

### Étape 7 — Nettoyage des applications Fedora

Chaque suppression hors remplacement conditionnel est contrôlée par une option explicite :

| Option | Application | Paquet Fedora ciblé |
| --- | --- | --- |
| `SUPPRESSION_MEDIA_WRITER` | Fedora Media Writer | `mediawriter` |
| `SUPPRESSION_CARTES` | Cartes | `gnome-maps` |
| `SUPPRESSION_LIBREOFFICE` | Suite LibreOffice | tous les paquets installés nommés `libreoffice*` |
| `SUPPRESSION_NUMERISEUR` | Numériseur de documents | `simple-scan` |
| `SUPPRESSION_MACHINES` | Machines | `gnome-boxes` |
| `SUPPRESSION_CAMERA` | Caméra | `snapshot`, ou l'ancien `cheese` s'il subsiste |
| `SUPPRESSION_CONNEXIONS` | Connexions | `gnome-connections` |
| `SUPPRESSION_CONTROLE_PARENTAL` | Contrôle parental | `malcontent-control` |
| `SUPPRESSION_VISITE_GUIDEE` | Visite guidée | `gnome-tour` |
| `SUPPRESSION_AIDE` | Aide GNOME | `yelp` |

Le script construit une liste de noms de paquets installés exacte, sans transmettre de glob non résolu à DNF, puis effectue une seule transaction `dnf remove`. Si `INSTALL_MPV=true` et que `mpv` est présent, il ajoute `showtime` et l'ancien `totem` s'ils sont installés. Si `INSTALL_BRAVE=true` et que `brave-browser` est présent, il ajoute `firefox` et `firefox-langpacks`.

Après cette transaction, `dnf autoremove` retire les dépendances que DNF marque comme inutilisées. Les deux transactions sont sensibles et ne reçoivent `--assumeyes` que lorsque `AUTO_CONFIRM_ALL_ACTIONS=true`. L'étape possède son propre checkpoint et reste idempotente.

## Étape optionnelle et expérimentale — Noyau CachyOS

Le parcours reprend la procédure du dépôt [`CachyOS/copr-linux-cachyos`](https://github.com/CachyOS/copr-linux-cachyos) et les contrôles pratiques du [guide Linuxtricks](https://www.linuxtricks.fr/wiki/fedora-installer-le-noyau-de-cachyos-pour-de-meilleures-perfs-gaming). Il installe un noyau tiers sur Fedora ; il ne transforme pas le système en CachyOS.

`INSTALL_CACHYOS=false` est la valeur par défaut. La valeur `true` constitue un choix explicite pour tester cette solution, de préférence sur un PC secondaire. Le script affiche toujours l'avertissement avant de poursuivre, même lorsque les actions sûres sont confirmées automatiquement.

Le socle installé lorsque `INSTALL_CACHYOS=true` comprend :

- le dépôt COPR GCC `bieszczaders/kernel-cachyos` ;
- `kernel-cachyos` ;
- `kernel-cachyos-devel-matched`.

La variante LLVM et les noyaux LTS/RT/server restent hors périmètre. Lorsque `INSTALL_CACHYOS_ADDONS=true`, le script ajoute après validation du noyau :

- `cachyos-settings`, en remplacement de `zram-generator-defaults` ;
- `scx-scheds`, `scx-tools` et `scx-manager` ;
- `ananicy-cpp`, avec activation de son service.

Si `INSTALL_CACHYOS=false`, la valeur de `INSTALL_CACHYOS_ADDONS` est ignorée sans activer de dépôt ni modifier ZRAM.

### Prévalidation obligatoire

Avant d'activer le COPR, le script devra :

1. confirmer Fedora Workstation RPM sur `x86_64` ;
2. vérifier que `x86-64-v3` apparaît dans la sortie suivante ;
3. vérifier l'espace disponible dans `/boot` pour un noyau supplémentaire ;
4. inventorier les noyaux Fedora et mémoriser le noyau par défaut courant ;
5. enregistrer la valeur de `GRUB_DEFAULT` et l'état SELinux de `domain_kernel_load_modules` ;
6. vérifier Secure Boot ;
7. vérifier la compatibilité du pilote NVIDIA lorsqu'un GPU NVIDIA est présent.

```bash
/lib64/ld-linux-x86-64.so.2 --help | grep '(supported, searched)'
df -h /boot
sudo grubby --default-kernel
getsebool domain_kernel_load_modules
mokutil --sb-state
```

L'absence de `x86-64-v3`, d'un noyau Fedora amorçable ou d'espace suffisant bloque l'étape.

Le guide Linuxtricks indique que ce noyau n'est pas signé comme celui de Fedora. Si Secure Boot est actif, le script s'arrête **avant toute modification**, demande sa désactivation manuelle dans l'UEFI et indique de relancer avec `--resume`. Il ne tente jamais de modifier l'UEFI.

Depuis le 23 février 2026, le dépôt CachyOS ne fournit plus de pilotes NVIDIA précompilés. Avec NVIDIA, la branche RPM Fusion compatible doit donc être installée et `akmods` doit pouvoir construire le module pour le noyau CachyOS avant le premier redémarrage.

### Installation

```bash
sudo dnf copr enable bieszczaders/kernel-cachyos
sudo dnf install kernel-cachyos kernel-cachyos-devel-matched
```

Lors de l'import initial, l'empreinte attendue de la clé COPR est :

```text
537D EED3 3436 B036 7F5B 26D5 B3E3 132C F108 59CF
```

Une empreinte différente bloque l'installation. Le script vérifie ensuite que les paquets appartiennent bien au dépôt attendu et qu'un fichier `/boot/vmlinuz-*-cachyos*` existe.

Si SELinux est actif et que le booléen vaut `off`, le script applique :

```bash
sudo setsebool -P domain_kernel_load_modules on
```

Il enregistre le fait qu'il a effectué cette modification afin de pouvoir la restaurer lors de la désinstallation.

Le noyau Fedora mémorisé avant l'installation est ensuite redéfini comme choix par défaut. Le script programme `menu_show_once=1` avec `grub2-editenv` afin d'afficher GRUB au prochain démarrage uniquement. `AUTO_REBOOT` est ignoré à ce stade : l'utilisateur doit redémarrer manuellement et sélectionner le noyau CachyOS dans GRUB.

### Validation après redémarrage

Après `--resume`, le script exige que `uname -r` contienne `cachy` ou `cachyos`. Il vérifie ensuite :

- que le noyau courant appartient à un paquet CachyOS installé ;
- l'absence d'échec critique dans `systemctl --failed` ;
- l'accélération graphique applicable ;
- `nvidia-smi` et le module NVIDIA sur une machine concernée ;
- la présence persistante d'au moins un noyau Fedora.

Un échec laisse Fedora comme noyau par défaut et n'installe aucun mécanisme de sélection automatique.

### Addons CachyOS

Cette étape n'est exécutée qu'après un premier démarrage CachyOS réussi et seulement avec `INSTALL_CACHYOS_ADDONS=true`. Le script enregistre d'abord la configuration ZRAM, l'état des services et les paquets présents afin de permettre un retour arrière exact.

```bash
sudo dnf copr enable bieszczaders/kernel-cachyos-addons

sudo dnf swap zram-generator-defaults cachyos-settings
sudo dracut -f

sudo dnf install scx-scheds scx-tools scx-manager
sudo dnf install ananicy-cpp
sudo systemctl enable --now ananicy-cpp
```

Le script vérifie chaque transaction séparément. Il ne passe à la suivante que si la précédente est validée et enregistre notamment :

- si `zram-generator-defaults` était installé avant le `swap` ;
- les paramètres et périphériques ZRAM observés avant modification ;
- si `ananicy-cpp` était déjà installé, activé ou démarré ;
- la liste exacte des paquets addons installés par cette exécution.

Le remplacement ZRAM et la régénération de l'initramfs nécessitent un nouveau démarrage pour une validation complète. `AUTO_REBOOT` reste ignoré : l'utilisateur redémarre manuellement et sélectionne à nouveau CachyOS dans GRUB.

Après reprise, le script vérifie :

- que le noyau courant est toujours CachyOS ;
- que `cachyos-settings` a remplacé `zram-generator-defaults` ;
- la présence d'un périphérique ZRAM cohérent avec `zramctl` ;
- la présence de `scx-scheds`, `scx-tools` et `scx-manager` ;
- que `ananicy-cpp` est activé et actif.

Après la validation du noyau et, le cas échéant, des addons, `HIDE_GRUB_AFTER_CACHYOS=true` supprime un éventuel `menu_show_once` résiduel puis définit `menu_auto_hide=1` avec `grub2-editenv`. Ce mécanisme Fedora masque GRUB sur une installation mono-système après un démarrage réussi, tout en préservant son affichage en multiboot ou après un échec.

Les ordonnanceurs `sched-ext` et Ananicy peuvent fonctionner ensemble. En cas de blocage ou d'instabilité, le premier diagnostic consiste à arrêter et désactiver `ananicy-cpp`, sans supprimer immédiatement le noyau.

### Maintien de CachyOS comme noyau par défaut

Après validation du noyau et, s'ils sont activés, de ses addons, le script applique le mécanisme DNF5 recommandé par le dépôt officiel :

```bash
sudo dnf install libdnf5-plugin-actions
sudo install -d -m 0755 /etc/dnf/libdnf5-plugins/actions.d
```

L'action `cachy-default.actions` sera créée par le script et appellera un helper géré par le projet. Ce helper devra :

- interroger `grubby --info=ALL` ;
- sélectionner le dernier chemin `/boot/vmlinuz-*` contenant `cachy` ;
- vérifier que la valeur n'est pas vide, qu'elle reste sous `/boot` et que le fichier existe ;
- appeler `grubby --set-default` uniquement après ces contrôles ;
- ne jamais faire échouer une transaction DNF lorsqu'aucun noyau CachyOS n'est présent.

Le script utilisera ce mécanisme DNF5, et non simultanément le hook `kernel-install` de Linuxtricks, afin d'éviter deux sources concurrentes de sélection du noyau. Si `GRUB_DEFAULT=saved` est nécessaire, son ancienne valeur est sauvegardée avant modification.

### Sous-script de désinstallation

`scripts/uninstall-cachyos.sh` devra fonctionner indépendamment du script principal et accepter `--dry-run`, `--resume` et `--help`.

Son déroulement sera :

1. inventorier les noyaux, paquets, COPR et fichiers gérés par le projet ;
2. trouver le dernier noyau Fedora installé, vérifier son chemin et le définir par défaut ;
3. si le noyau courant est CachyOS, enregistrer l'état `pending-fedora-reboot`, demander un redémarrage sur Fedora et quitter sans supprimer de paquet ;
4. après reprise sur Fedora, retirer uniquement l'action DNF5 et le helper portant la signature de gestion du projet ;
5. si les addons ont été installés par le projet, restaurer leur état dans l'ordre inverse : arrêter Ananicy, remettre `zram-generator-defaults`, exécuter `dracut -f`, retirer les paquets addons exacts et désactiver leur COPR ;
6. construire la liste exacte des paquets du noyau CachyOS, afficher la transaction et demander confirmation avant `dnf remove` ;
7. désactiver le COPR `bieszczaders/kernel-cachyos` ;
8. restaurer `GRUB_DEFAULT`, le booléen SELinux et l'ancien état d'Ananicy uniquement lorsque le projet les avait modifiés ;
9. vérifier le noyau Fedora par défaut et l'absence de paquet, dépôt ou hook CachyOS résiduel.

Le retour à la configuration ZRAM Fedora utilise, uniquement lorsque le `swap` initial a été enregistré :

```bash
sudo dnf swap cachyos-settings zram-generator-defaults
sudo dracut -f
```

Le sous-script ne doit jamais utiliser un numéro de noyau codé en dur, transmettre une variable vide à `grubby`, supprimer un noyau Fedora ou employer un glob non résolu avec `dnf remove`. En cas d'état ambigu, il s'arrête avec les commandes de diagnostic à fournir plutôt que de forcer la suppression.

---

## Annexes techniques

### Configuration DNF

DNF5 ne prend plus en charge `deltarpm`. `fastestmirror` peut également dégrader la sélection effectuée par les metalinks Fedora. Le script ajoutera donc seulement :

```ini
# /etc/dnf/libdnf5.conf.d/90-fedora-setup.conf
[main]
max_parallel_downloads=10
```

Il ne modifiera pas `defaultyes`, `keepcache` ou la configuration Fedora existante.

### Dépôts

Les dépôts tiers proposés par Fedora et RPM Fusion sont deux choix distincts :

```bash
# Sélection Fedora limitée et facultative
sudo fedora-third-party enable

# RPM Fusion Free et Nonfree, après confirmation
sudo dnf install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

flatpak remote-add --if-not-exists --system \
  flathub https://dl.flathub.org/repo/flathub.flatpakrepo
```

Avant l'ajout, l'implémentation doit valider que `rpm -E %fedora` renvoie exactement la version Fedora attendue. Après l'ajout, elle doit afficher les dépôts activés et refuser un dépôt Rawhide sur Fedora stable.

### Codecs multimédias

Ces opérations nécessitent RPM Fusion. Le `swap` n'est exécuté que si `ffmpeg-free` est installé :

```bash
sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1

if rpm -q ffmpeg-free >/dev/null 2>&1; then
  sudo dnf swap ffmpeg-free ffmpeg --allowerasing
else
  sudo dnf install ffmpeg
fi

sudo dnf install --setopt=install_weak_deps=False \
  gstreamer1-plugins-good \
  gstreamer1-plugins-bad-free \
  gstreamer1-plugins-bad-freeworld \
  gstreamer1-plugins-ugly \
  gstreamer1-plugins-ugly-free \
  gstreamer1-plugin-openh264 \
  gstreamer1-plugin-libav \
  --exclude=PackageKit-gstreamer-plugin
```

### Accélération matérielle

Le script traite tous les GPU détectés plutôt que d'en sélectionner un seul :

- Intel récent : `intel-media-driver` ;
- ancien Intel : `libva-intel-driver` ;
- AMD : `mesa-vulkan-drivers`, puis remplacement conditionnel de `mesa-va-drivers` par `mesa-va-drivers-freeworld` ;
- outils de validation : `libva-utils` et `vulkan-tools`.

```bash
sudo dnf install mesa-vulkan-drivers libva-utils vulkan-tools

if rpm -q mesa-va-drivers >/dev/null 2>&1; then
  sudo dnf swap mesa-va-drivers mesa-va-drivers-freeworld
else
  sudo dnf install mesa-va-drivers-freeworld
fi
```

Le remplacement Mesa ne concerne qu'AMD. Sur une machine hybride, les paquets Intel ou NVIDIA appropriés sont installés en complément.

### NVIDIA

Le script ne doit pas installer aveuglément la branche courante. Il devra relever l'identifiant PCI du GPU, vérifier la branche RPM Fusion compatible et faire confirmer le choix. Les branches héritées disponibles évoluent et doivent être résolues au moment de l'exécution.

Exemple pour un GPU pris en charge par la branche courante :

```bash
sudo dnf install akmod-nvidia

# Facultatif : CUDA, NVDEC et NVENC
sudo dnf install xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-cuda-libs

# Diagnostics VA-API, VDPAU et Vulkan
sudo dnf install vdpauinfo libva-nvidia-driver libva-utils vulkan-tools
```

`libva-vdpau-driver` n'est pas utilisé : il n'est pas disponible dans les dépôts Fedora 44 vérifiés. `libva-nvidia-driver` est le paquet prévu pour la pile NVIDIA actuelle.

Avec Secure Boot actif, le script doit s'arrêter et guider l'utilisateur dans la création puis l'enrôlement d'une clé MOK selon la documentation RPM Fusion. Il ne doit pas désactiver Secure Boot.

Avant redémarrage :

```bash
target_kernel_path="$(sudo grubby --default-kernel)"
target_kernel_version="${target_kernel_path#/boot/vmlinuz-}"
sudo akmods --force --rebuild --kernels "$target_kernel_version"
modinfo -k "$target_kernel_version" -F version nvidia
modinfo -k "$target_kernel_version" -F signer nvidia
```

Après redémarrage, vérifier au minimum `/proc/modules`, `nvidia-smi`, `vainfo` et `vulkaninfo --summary`. Un simple succès de `modinfo` ne prouve pas que le module est chargé. La lecture directe de `/proc/modules` évite le faux négatif que peut provoquer `lsmod | grep -q` avec `pipefail`.

### AppImage

```bash
sudo dnf install fuse-libs
flatpak install --system flathub it.mijorus.gearlever
```

Gear Lever est facultatif ; `fuse-libs` suffit à de nombreuses AppImage.
`INSTALL_GEARLEVER=true` contrôle uniquement l'installation de l'interface Flatpak.

### Outils GNOME

```bash
sudo dnf install \
  gnome-tweaks \
  gnome-extensions-app \
  gnome-shell-extension-user-theme \
  gnome-shell-extension-appindicator \
  gnome-shell-extension-dash-to-dock \
  gnome-shell-extension-blur-my-shell

flatpak install --system flathub com.mattjakeman.ExtensionManager
```

`extension-manager` n'est pas un paquet RPM Fedora 44. Chaque extension GNOME doit être prévalidée et installée séparément afin qu'un paquet indisponible ne fasse pas échouer toute l'étape.

### Zsh et polices

```bash
sudo dnf install zsh zsh-autosuggestions zsh-syntax-highlighting
sudo dnf install fira-code-fonts rsms-inter-fonts
```

Oh My Zsh sera installé comme utilisateur courant avec `RUNZSH=no` et `CHSH=no`. Le script devra rendre ses modifications de `~/.zshrc` idempotentes, appliquer `ZSH_THEME="clean"`, charger les scripts Fedora des deux extensions Zsh, puis proposer `chsh`.

Fira Sans n'est pas disponible comme RPM Fedora 44 sous le nom précédemment envisagé. La dernière release globale Mozilla, 4.202, ne contient que la variante Condensed ; le script épingle donc la dernière publication de Fira Sans classique, `4.106`, depuis [Mozilla Fira](https://github.com/mozilla/Fira/releases). Il enregistre la version et le checksum de l'archive, installe les fichiers dans `~/.local/share/fonts`, exécute `fc-cache -f` puis vérifie avec `fc-match "Fira Sans"`.

### Applications personnelles

Les commandes suivantes sont filtrées selon les options `INSTALL_*`. Les applications Fedora sont installées séparément des Flatpak afin de pouvoir signaler précisément un échec :

```bash
sudo dnf install mpv pinta clamav clamav-freshclam

flatpak install --system flathub \
  com.bitwarden.desktop \
  org.upscayl.Upscayl \
  com.rustdesk.RustDesk \
  io.github.linx_systems.ClamUI
```

Brave utilise son dépôt RPM officiel :

```bash
sudo dnf install dnf-plugins-core
sudo dnf config-manager addrepo \
  --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
sudo dnf install brave-browser
```

Après confirmation, le script pourra définir Brave et MPV par défaut sans supprimer les applications Fedora :

```bash
xdg-settings set default-web-browser brave-browser.desktop
xdg-mime default mpv.desktop video/mp4
xdg-mime default mpv.desktop video/x-matroska
xdg-mime default mpv.desktop video/webm
```

ClamUI est l'interface GTK4/libadwaita retenue. Sa version Flatpak ne fournit pas le moteur antivirus : elle appelle le ClamAV installé sur l'hôte. La mise à jour initiale des signatures sera lancée avec `sudo freshclam`. Son échec ne doit pas être masqué, notamment si un service `freshclam` possède déjà le verrou de la base.

### Jeux

Steam, Lutris, GameMode et Gamescope sont installés comme paquets natifs pour conserver leur accès aux pilotes, périphériques et outils de l'hôte :

```bash
sudo dnf install steam lutris gamescope
sudo dnf install gamemode gamemode.i686
```

`steam` provient de RPM Fusion Nonfree ; le script doit donc vérifier ce dépôt avant l'installation. La variante 32 bits de GameMode est installée avec GameMode lorsque l'architecture `x86_64` et les dépôts multilib le permettent.

Bottles et Heroic sont installés depuis Flathub :

```bash
flatpak install --system flathub \
  com.usebottles.bottles \
  com.heroicgameslauncher.hgl
```

Chaque commande dépend de sa clé de configuration. L'étape valide au minimum `rpm -q` ou `flatpak info`, `gamemoded -t`, `gamescope --version` et `lutris --version` lorsqu'ils sont applicables. Un échec d'un lanceur ne doit pas annuler les autres installations déjà validées.

### Node.js avec NVM

Node.js est installé par utilisateur avec [NVM](https://github.com/nvm-sh/nvm). La version NVM est épinglée ; le dernier correctif de Node 24 LTS est ensuite résolu et enregistré :

```bash
NVM_VERSION=v0.40.6
nvm_installer="$(mktemp)"
trap 'rm -f -- "$nvm_installer"' EXIT

curl -fsSL \
  "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" \
  -o "$nvm_installer"
PROFILE="$HOME/.zshrc" bash "$nvm_installer"

if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
  export NVM_DIR="$XDG_CONFIG_HOME/nvm"
else
  export NVM_DIR="$HOME/.nvm"
fi
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

nvm install 24
nvm alias default 24
nvm use default
npm install --global pnpm@latest

node --version
pnpm --version
```

Node 24 est la version LTS courante lors de cette révision. Le script doit vérifier que la version résolue commence par `v24.` et ne jamais utiliser `sudo npm` avec NVM.

### Docker

Le script utilise le [dépôt RPM officiel Docker](https://docs.docker.com/engine/install/fedora/), pas le script de commodité `get.docker.com`.

Avant l'installation, il doit détecter les paquets en conflit documentés par Docker et demander confirmation avant toute suppression.

```bash
sudo dnf config-manager addrepo \
  --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo

sudo dnf install \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

sudo systemctl enable --now docker

# Validation immédiate demandée
sudo docker run --rm hello-world
docker compose version

# Inclus par INSTALL_DOCKER=true, après avertissement sur les privilèges accordés
sudo usermod -aG docker "$(id -un)"
```

L'ajout au groupe `docker` fait partie de `INSTALL_DOCKER=true`. Il prend effet après une nouvelle connexion et accorde des privilèges comparables à ceux de `root`. Le test `hello-world` doit réussir avant que l'étape soit marquée comme terminée.

### Outils de développement

Visual Studio Code sera installé depuis le dépôt RPM officiel Microsoft après import de sa clé et affichage du dépôt ajouté :

```bash
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc

sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

sudo dnf install code
```

Bruno et Desktop Plus sont installés via Flathub :

```bash
flatpak install --system flathub \
  com.usebruno.Bruno \
  org.desktop_plus.desktop-plus
```

Le script doit vérifier chaque identifiant séparément avant la transaction.

### RTK

RTK doit être installé dans sa **dernière version disponible** depuis le projet [`rtk-ai/rtk`](https://github.com/rtk-ai/rtk). L'installateur officiel résout la dernière release, télécharge `checksums.txt` et vérifie le SHA-256 du binaire. Pour éviter l'exécution directe d'un pipeline distant, le script est d'abord téléchargé dans un fichier temporaire :

```bash
rtk_installer="$(mktemp)"
trap 'rm -f -- "$rtk_installer"' EXIT

curl -fsSL \
  https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh \
  -o "$rtk_installer"
sh "$rtk_installer"

rtk --version
rtk gain
```

`rtk gain` permet notamment de détecter une collision avec un autre programme nommé `rtk`. La version réellement installée doit être enregistrée dans l'état. Le script n'exécute aucune commande `rtk init` propre à un assistant : l'utilisateur choisira et configurera lui-même son outil IA.

### Outils en ligne de commande

```bash
sudo dnf install ripgrep fd-find fzf bat
sudo dnf install eza zoxide jq htop tree git-delta tokei
```

Les paquets doivent être interrogés puis installés individuellement ou par groupes prévalidés, sans masquer un paquet indisponible avec `--skip-unavailable`.

## Validation finale

Le script ne déclarera son exécution réussie qu'après les contrôles applicables :

- `sudo dnf check` et absence de dépôt Rawhide activé ;
- `flatpak info` pour chaque application Flatpak demandée ;
- `vainfo` et `vulkaninfo --summary`, plus `nvidia-smi` si nécessaire ;
- `sudo docker run --rm hello-world` et `docker compose version` ;
- `node --version`, `pnpm --version`, `rtk --version` et `rtk gain` ;
- validations des jeux sélectionnés avec `rpm -q`, `flatpak info` et leurs commandes de diagnostic ;
- `fc-match` pour Fira Code, Fira Sans et Inter ;
- vérification des applications par défaut choisies ;
- résumé des opérations ignorées, échouées ou nécessitant un redémarrage.

## Sources principales

- [Documentation Fedora DNF5](https://dnf5.readthedocs.io/)
- [Compression transparente Btrfs dans Fedora](https://fedoraproject.org/wiki/Changes/BtrfsTransparentCompression)
- [RPM Fusion](https://rpmfusion.org/Configuration)
- [Docker Engine sur Fedora](https://docs.docker.com/engine/install/fedora/)
- [NVM — dépôt officiel](https://github.com/nvm-sh/nvm)
- [Brave sur Linux](https://brave.com/linux/)
- [Visual Studio Code sur Linux](https://code.visualstudio.com/docs/setup/linux)
- [Desktop Plus sur Flathub](https://flathub.org/apps/org.desktop_plus.desktop-plus)
- [Bruno — installation](https://docs.usebruno.com/get-started/bruno-basics/download)
- [ClamUI — projet officiel](https://github.com/linx-systems/clamui)
- [ClamUI sur Flathub](https://flathub.org/apps/io.github.linx_systems.ClamUI)
- [Bottles sur Flathub](https://flathub.org/apps/com.usebottles.bottles)
- [Heroic sur Flathub](https://flathub.org/apps/com.heroicgameslauncher.hgl)
- [RTK](https://github.com/rtk-ai/rtk)
- [CachyOS COPR pour Fedora](https://github.com/CachyOS/copr-linux-cachyos)
- [Guide CachyOS pour Fedora — Linuxtricks](https://www.linuxtricks.fr/wiki/fedora-installer-le-noyau-de-cachyos-pour-de-meilleures-perfs-gaming)

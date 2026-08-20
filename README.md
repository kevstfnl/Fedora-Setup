# Fedora Setup

Script de post-installation interactif pour **Fedora Workstation 44 avec GNOME**. Il permet de préparer une installation Fedora, d'ajouter les applications choisies et de configurer un environnement bureautique, de développement et de jeu depuis un simple fichier `config.ini`.

Le script explique chaque action dans le terminal, demande confirmation pour les opérations sensibles et conserve un journal ainsi que des points de reprise.

> [!WARNING]
> Ce projet cible uniquement Fedora Workstation 44 classique sur `x86_64`. Il ne prend pas en charge Silverblue, Kinoite ni les autres éditions Atomic. Ne lancez jamais le script avec `sudo` : il demandera lui-même les droits nécessaires.

## Ce que le script peut installer

- mises à jour Fedora, RPM Fusion, Flathub et codecs multimédias ;
- pilotes et accélération vidéo adaptés aux GPU AMD, Intel ou NVIDIA ;
- outils GNOME, Zsh, Oh My Zsh et polices supplémentaires ;
- Brave, Bitwarden, MPV, Pinta, Upscayl, RustDesk, ClamAV, ClamUI et Gear Lever ;
- Node.js 24 LTS avec NVM, pnpm, Docker Engine, VS Code, Bruno, Desktop Plus et RTK ;
- Steam, Bottles, Lutris, Heroic, GameMode et Gamescope ;
- suppression configurable des applications Fedora préinstallées inutilisées, suivie de `dnf autoremove` ;
- en option, le noyau CachyOS et ses addons expérimentaux.

La spécification technique complète et les choix d'implémentation sont disponibles dans [`PLANS.md`](PLANS.md).

## Prérequis

Avant de commencer, vérifiez que vous disposez de :

- Fedora Workstation 44 avec GNOME sur une machine `x86_64` ;
- une connexion Internet fonctionnelle ;
- au moins 5 Gio disponibles sur la partition racine ;
- un compte utilisateur autorisé à utiliser `sudo` ;
- une sauvegarde récente de vos données importantes.

Placez-vous ensuite dans le dossier du projet :

```bash
cd Fedora-Setup
```

Les scripts sont déjà exécutables. Si leurs permissions ont été perdues après une copie, restaurez-les avec :

```bash
chmod +x fedora-setup.sh scripts/*.sh tests/run.sh
```

## 1. Choisir ce qui sera installé

Ouvrez [`config.ini`](config.ini) dans votre éditeur. Chaque fonctionnalité utilise une valeur simple :

```ini
INSTALL_BRAVE=true
INSTALL_PINTA=false
```

- `true` : la fonctionnalité est activée ;
- `false` : la fonctionnalité est ignorée.

Les commentaires présents dans le fichier expliquent les conséquences des options importantes. La configuration fournie active la majorité des applications, mais laisse CachyOS désactivé.

### Options générales

| Option | Effet |
| --- | --- |
| `AUTO_CONFIRM_SAFE_ACTIONS` | Confirme les installations ordinaires et répond automatiquement aux invites DNF/Flatpak correspondantes. Les opérations sensibles restent interactives. |
| `AUTO_CONFIRM_ALL_ACTIONS` | Active le mode sans surveillance pour les confirmations sensibles et leurs transactions DNF. Ne contourne ni `sudo`, ni Secure Boot, ni les redémarrages de test CachyOS. |
| `AUTO_REBOOT` | Autorise un redémarrage automatique après un délai de 10 secondes lorsqu'il est nécessaire. |
| `NVIDIA_DRIVER` | `auto` choisit une branche RPM Fusion compatible ; `disabled` interdit l'installation du pilote propriétaire. |
| `INSTALL_HARDWARE_CODECS` | Installe les codecs et l'accélération vidéo adaptés au matériel détecté. |

> [!IMPORTANT]
> La configuration fournie contient actuellement `AUTO_REBOOT=true`. Passez cette option à `false` si vous souhaitez décider vous-même du moment du redémarrage.

### Options liées entre elles

- `INSTALL_CLAMUI=true` active également ClamAV, car ClamUI est seulement une interface graphique ;
- `INSTALL_DOCKER=true` installe Docker, démarre son service, exécute `hello-world` et ajoute l'utilisateur au groupe `docker` ;
- `INSTALL_NODE=true` installe le dernier correctif de Node.js 24 LTS via NVM, puis pnpm ;
- `INSTALL_CACHYOS_ADDONS` et `HIDE_GRUB_AFTER_CACHYOS` sont ignorés lorsque `INSTALL_CACHYOS=false` ;
- le lecteur vidéo Fedora est supprimé uniquement si MPV a réellement été installé ;
- Firefox est supprimé uniquement si Brave a réellement été installé.

### Supprimer les applications Fedora inutilisées

Chaque application possède une option `SUPPRESSION_*` indépendante dans `config.ini`. La valeur `true` constitue la confirmation explicite de sa suppression : Media Writer, Cartes, LibreOffice, Numériseur de documents, Machines, Caméra, Connexions, Contrôle parental, Visite guidée ou Aide GNOME.

Toutes les applications encore présentes sont regroupées dans une seule transaction DNF. Le script lance ensuite `dnf autoremove` pour retirer les dépendances que DNF considère comme devenues inutiles. Avec `AUTO_CONFIRM_ALL_ACTIONS=false`, DNF affiche la transaction et attend encore une validation au terminal ; avec `true`, le nettoyage est exécuté sans surveillance.

> [!CAUTION]
> Vérifiez le plan avec `--dry-run` et conservez seulement les suppressions souhaitées. `dnf autoremove` peut proposer des bibliothèques utiles à un usage non détecté par DNF.

Le fichier ne doit contenir aucun mot de passe, jeton ou autre secret.

## 2. Valider la configuration

Avant toute simulation ou installation, vérifiez le fichier :

```bash
./fedora-setup.sh --validate-config
```

Le parseur refuse notamment les clés inconnues, les doublons et les valeurs différentes de `true`, `false`, `auto` ou `disabled` selon l'option.

Pour utiliser un autre fichier de configuration :

```bash
./fedora-setup.sh --config ./ma-config.ini --validate-config
```

## 3. Simuler l'installation

La simulation affiche le plan, contrôle la compatibilité de la machine et montre les commandes prévues sans modifier le système :

```bash
./fedora-setup.sh --dry-run
```

Il est fortement recommandé de lire cette sortie avant le premier lancement réel. Les lignes marquées `[dry-run]` indiquent les commandes ou changements qui seraient effectués.

## 4. Lancer l'installation

Exécutez le script depuis votre session GNOME normale :

```bash
./fedora-setup.sh
```

N'utilisez pas `sudo ./fedora-setup.sh`. Le script refuse volontairement une exécution directe en tant que `root` et demande `sudo` seulement pour les opérations système.

Pendant l'exécution :

- les étapes et commandes sont affichées clairement ;
- les installations ordinaires suivent `AUTO_CONFIRM_SAFE_ACTIONS` ;
- les suppressions, remplacements de paquets et changements sensibles suivent `AUTO_CONFIRM_ALL_ACTIONS` ;
- une erreur bloque l'étape concernée sans effacer les opérations déjà validées ;
- le script indique lorsqu'une reconnexion ou un redémarrage est nécessaire.

## Reprendre une exécution

Après une interruption ou un redémarrage demandé par le script, utilisez :

```bash
./fedora-setup.sh --resume
```

Les opérations terminées possèdent un point de contrôle et ne sont pas rejouées inutilement. Si un redémarrage est enregistré comme nécessaire, une exécution normale sans `--resume` sera refusée afin d'éviter de poursuivre dans un état incohérent.

Lors du redémarrage final, le script enregistre l'identifiant du démarrage courant. Au lancement suivant, un nouvel identifiant acquitte automatiquement la recommandation afin d'éviter une boucle de redémarrages.

## Exécuter seulement certaines étapes

Les étapes disponibles sont :

| Étape | Contenu principal |
| --- | --- |
| `prepare` | contrôles, configuration DNF, audit Btrfs et mise à jour Fedora |
| `repositories` | dépôts, codecs et pilotes graphiques |
| `desktop` | GNOME, Zsh, AppImage et polices |
| `apps` | applications personnelles |
| `development` | Node.js, Docker, VS Code, Bruno, Desktop Plus, RTK et outils CLI |
| `gaming` | Steam et outils de jeu |
| `cleanup` | applications Fedora préinstallées et dépendances devenues inutiles |
| `cachyos` | noyau et addons CachyOS expérimentaux |
| `validation` | contrôles fonctionnels finaux |

Exécuter uniquement les applications et les outils de développement :

```bash
./fedora-setup.sh --only apps --only development
```

Ignorer temporairement les jeux :

```bash
./fedora-setup.sh --skip gaming
```

Les options `--only` et `--skip` peuvent être répétées.

## Modifier temporairement une option

`--set` surcharge une valeur sans modifier `config.ini` :

```bash
./fedora-setup.sh --dry-run --set INSTALL_STEAM=false
```

Plusieurs valeurs peuvent être surchargées :

```bash
./fedora-setup.sh --only apps \
  --set INSTALL_BRAVE=true \
  --set INSTALL_UPSCAYL=false
```

La priorité est la suivante : valeurs internes, puis `config.ini`, puis options `--set`.

## Utiliser CachyOS

CachyOS est une option expérimentale destinée de préférence à un PC secondaire. Elle installe un noyau tiers tout en conservant un noyau Fedora amorçable.

Avant de l'activer :

1. sauvegardez vos données ;
2. vérifiez que Secure Boot est désactivé dans l'UEFI ;
3. conservez l'accès au menu GRUB ;
4. testez d'abord le parcours avec `--dry-run`.

Activez ensuite dans `config.ini` :

```ini
INSTALL_CACHYOS=true
INSTALL_CACHYOS_ADDONS=true
HIDE_GRUB_AFTER_CACHYOS=true
```

Le déroulement comprend plusieurs lancements volontaires :

1. le script installe le noyau mais garde Fedora par défaut, puis s'arrête ;
2. le script programme l'affichage de GRUB pour le prochain démarrage uniquement ;
3. redémarrez et sélectionnez manuellement CachyOS dans GRUB ;
4. si GRUB reste masqué par le firmware, maintenez la touche `Maj` gauche ou tapotez `F8` pendant le démarrage ;
5. exécutez `./fedora-setup.sh --resume` pour valider le noyau et installer les addons ;
6. redémarrez une seconde fois sur CachyOS ;
7. exécutez à nouveau `./fedora-setup.sh --resume` pour valider les addons et terminer la configuration ;
8. après ces validations, `HIDE_GRUB_AFTER_CACHYOS=true` réactive automatiquement le masquage conditionnel Fedora.

Le masquage ne s'applique normalement qu'à une machine mono-système après un démarrage réussi. En multiboot ou après un échec de démarrage, Fedora conserve le menu. Vous pouvez toujours le faire apparaître en maintenant `Maj` gauche ou en tapotant `F8`.

Si Secure Boot est actif, le script s'arrête avant d'ajouter le dépôt ou d'installer le noyau. Il ne tente jamais de modifier les réglages UEFI.

### Désinstaller CachyOS

Commencez par simuler la procédure :

```bash
./scripts/uninstall-cachyos.sh --dry-run
```

Puis lancez la désinstallation réelle :

```bash
./scripts/uninstall-cachyos.sh
```

Le désinstallateur sélectionne d'abord un noyau Fedora. Si la machine tourne encore sur CachyOS, il demande un redémarrage sans supprimer le noyau en cours d'utilisation. Après avoir redémarré sur Fedora, reprenez avec :

```bash
./scripts/uninstall-cachyos.sh --resume
```

Il retire ensuite uniquement les composants CachyOS reconnus comme gérés par le projet et restaure, lorsque nécessaire, ZRAM, GRUB et le réglage SELinux enregistré.

## Journaux et état de reprise

Les informations d'exécution sont stockées dans :

```text
${XDG_STATE_HOME:-$HOME/.local/state}/fedora-post-install/
```

Les fichiers importants sont :

- `main.log` : journal détaillé du script principal ;
- `uninstall-cachyos.log` : journal du désinstallateur ;
- `steps/` : opérations déjà terminées ;
- `values/` : versions résolues et informations nécessaires à la reprise.

En cas d'échec, consultez d'abord la fin du journal :

```bash
tail -n 100 "${XDG_STATE_HOME:-$HOME/.local/state}/fedora-post-install/main.log"
```

## Vérifier le projet

Les tests fournis contrôlent le parseur, les points d'entrée, la syntaxe Bash et plusieurs garde-fous :

```bash
./tests/run.sh
```

Pour vérifier seulement la syntaxe Bash :

```bash
bash -n fedora-setup.sh lib/*.sh scripts/*.sh tests/run.sh
```

## Aide-mémoire

```bash
# Afficher toutes les options
./fedora-setup.sh --help

# Valider config.ini
./fedora-setup.sh --validate-config

# Simuler sans modifier le système
./fedora-setup.sh --dry-run

# Lancer l'installation
./fedora-setup.sh

# Reprendre après interruption ou redémarrage
./fedora-setup.sh --resume

# Simuler la désinstallation de CachyOS
./scripts/uninstall-cachyos.sh --dry-run
```

## Structure du projet

```text
fedora-setup.sh                  point d'entrée principal
config.ini                      configuration utilisateur
README.md                       guide d'utilisation
PLANS.md                        spécification technique détaillée
lib/common.sh                   logs, état et garde-fous communs
lib/config.sh                   parseur strict de config.ini
lib/tasks.sh                    étapes Fedora et applications
lib/cachyos.sh                  parcours CachyOS
scripts/select-cachy-kernel.sh  sélection contrôlée du noyau
scripts/uninstall-cachyos.sh    désinstallation de CachyOS
tests/run.sh                    tests automatisés
```

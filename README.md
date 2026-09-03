# devconsole-registry

Registry des versions pour [DevConsole](https://github.com/Paul75/devconsole).

Ce dépôt contient le fichier `versions.json` qui liste les versions disponibles de chaque outil (Node.js, PHP, MySQL, MariaDB, Caddy, Python, Git) avec les URLs de téléchargement et les SHA256.

## Utilisation

DevConsole fetch ce fichier depuis `https://raw.githubusercontent.com/Paul75/devconsole-registry/main/versions.json` au démarrage. Si le réseau est absent, le fallback embarqué dans l'application est utilisé.

## Structure

```json
{
  "tools": {
    "<tool>": {
      "versions": {
        "<version>": {
          "url": "<download_url>",
          "sha256": "<optional_sha256>",
          "binaries": ["<binary_paths>"]
        }
      }
    }
  }
}
```

## Ajouter une version

1. Ajouter l'entrée dans `versions.json` (manuellement, ou via le script ci-dessous)
2. Publier le binaire dans une Release GitHub si besoin (PHP, Git Linux…)
3. Committer et pusher sur `main`

## Détecter / mettre à jour les versions

Le script [`scripts/check-versions.py`](scripts/check-versions.py) interroge les sources upstream et propose les bumps pour `versions.json`.

### Outils supportés

`node`, `bun`, `caddy`, `mailpit`, `composer`, `zed`, `vscodium`, `tabby`, `electerm`, `go`, `php`, `git`, `python`, `vscode`, `jdk`, `rust`, `postgres`, `mariadb`, `windterm`, `bruno`, `cloudflared`, `gh`, `jq`, `lazygit`, `mkcert`, `maven`, `uv`, `redis`, `mongodb`, `sqlite`, `android_studio`, `android_sdk`

| Outil | Source | Comportement |
|-------|--------|--------------|
| **node** | `nodejs.org/dist/index.json` + SHASUMS | remplace la version de chaque ligne majeure déjà présente |
| **go** | `go.dev/dl/?mode=json` | ajoute la nouvelle version (sha depuis l’API) |
| **php**, **git** | tags GitHub (`php/php-src`, `git/git`) | **detect-only** : signale la nouvelle version, le binaire étant produit par un build local/CI |
| **autres** | GitHub Releases `latest` | ajoute la nouvelle version (URL dérivée du template existant) |

`php` et `git` ne dérivent pas d’URL : leur binaire Linux est buildé localement
(ou en CI). Une fois la release publiée, [`scripts/update-builds.sh`](scripts/update-builds.sh)
intègre l’entrée dans `versions.json` (url + sha256 calculés sur l’artefact).

### Commandes

```bash
# Rapport seul (aucune écriture)
scripts/check-versions.py

# Sous-ensemble d'outils
scripts/check-versions.py --tool node,bun

# Sortie machine
scripts/check-versions.py --json

# Appliquer les mises à jour dans versions.json
scripts/check-versions.py --write

# Idem + calcul des sha256 par téléchargement (lent)
# Utile hors node/go, qui récupèrent déjà les checksums officiels
scripts/check-versions.py --write --sha

# Remplir les sha256 manquants (null/vides) des versions déjà présentes
# Indépendant des checkers : pas besoin de vérifier les nouveautés
scripts/check-versions.py --fill-sha
scripts/check-versions.py --fill-sha --write  # applique l'écriture

# Ajouter manuellement une version (entry JSON sur stdin) — usage interne
echo '{"url": "…", "sha256": "…"}' | scripts/check-versions.py --add php@8.5.10
```

Sans `--sha`, les outils GitHub mettent `sha256` / `sha256_windows` à `null`.
Pour combler les hashes manquants d’entrées déjà présentes (y compris celles
ajoutées sans `--sha`), relancer avec `--fill-sha` : il télécharge chaque URL
sans hash et remplit `sha256` / `sha256_windows`. Il respecte `--tool` et couvre
aussi les outils sans checker (`mysql`, `wezterm`, …).

Astuce rate-limit GitHub : exporter `GITHUB_TOKEN` (ou être authentifié via `gh auth login`).

Après `--write`, vérifier le diff, puis committer et pusher sur `main`.

### Mettre à jour PHP / Git (build local)

`scripts/update-builds.sh` automatise le cycle complet : détection → build →
release GitHub → mise à jour de `versions.json` avec les sha256 calculés sur
les artefacts publiés.

```bash
# php + git (build local via release-*.sh)
scripts/update-builds.sh

# Build via GitHub Actions (runner self-hosté actions-runner/ de ce dépôt)
scripts/update-builds.sh --ci

# Seulement php
scripts/update-builds.sh --tool php

# Release déjà publiée (rebuild manuel) : ne met à jour que versions.json
scripts/update-builds.sh --no-build
```

- **php** : construit le dernier patch de la branche mineure détectée
  (`release-php.sh <minor>` ou `build-php.yml`), l’URL Windows est cherchée sur
  `windows.php.net`.
- **git** : construit la version détectée (`release-git.sh <version>` ou
  `build-git.yml`), l’URL Windows pointe sur la dernière build MinGit de
  git-for-windows.
- Les `binaries` / `lts` de l’entrée précédente sont conservés.

> Avec `--ci`, le runner self-hosté de ce dépôt (`actions-runner/`) doit être
> en ligne (`./run.sh`) : il est enregistré sur `Paul75/devconsole-registry`
> mais n'est pas installé comme service systemd, il faut le lancer à la main.

## Build PHP

Les binaires PHP sont buildés avec [static-php-cli](https://static-php.dev) via GitHub Actions.

### Déclencher un build

Aller dans **Actions → Build PHP → Run workflow**, saisir la version mineure (e.g. `8.4`).

Le workflow:
1. Télécharge `spc` (le CLI de static-php-cli)
2. Compile PHP avec les extensions listées dans [`craft.yml`](craft.yml)
3. Crée un archive `.tar.gz` contenant `bin/php`, `sbin/php-fpm`, `bin/php-cgi`
4. Publie une GitHub Release avec l'archive

### Build en local

```bash
# Prérequis: autoconf, automake, libtool, cmake, make, gcc, g++, pkg-config,
#            re2c, bison, libxml2-dev, libsqlite3-dev, libcurl4-openssl-dev,
#            libreadline-dev, libzip-dev, libonig-dev, libssl-dev

curl -fsSL -o spc https://dl.static-php.dev/v3/spc-bin/nightly/spc-linux-x86_64
chmod +x spc
./spc craft craft.yml
```

Les binaires buildés se trouvent dans `buildroot/bin/php` et `buildroot/sbin/php-fpm`.

### URL des Releases

Une fois le build terminé, l'URL de téléchargement pour `versions.json` est:

```
https://github.com/Paul75/devconsole-registry/releases/download/php-{version}/php-{version}-fpm-linux-x86_64.tar.gz
```

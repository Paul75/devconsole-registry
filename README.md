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

1. Ajouter l'entrée dans `versions.json`
2. Publier le binaire dans une Release GitHub
3. Committer et pusher sur `main`

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

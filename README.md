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

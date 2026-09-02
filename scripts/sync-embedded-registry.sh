#!/usr/bin/env bash
# Synchronise versions.json (registry) vers l'embarquée du repo DevConsole
# (src-tauri/resources/versions.json).
#
# L'embarquée est compilée dans le binaire (include_str!) : elle sert de
# registry de secours hors ligne (1er lancement sans cache disque). Le
# refresh en arrière-plan la remplace dès que l'app est en ligne, donc un
# retard n'y est pas bloquant — mais il vaut mieux la garder proche du
# registry pour le mode portable.
#
# Usage :
#   scripts/sync-embedded-registry.sh            # copie versions.json → embarquée
#   scripts/sync-embedded-registry.sh --check    # compare seulement, code ≠0 si différent
#
# Résolution du repo DevConsole :
#   1. $DEVCONSOLE_REPO (variable d'env explicite)
#   2. parent du registry (repo DevConsole dans le même workspace, ex. devconsole-registry/)
#   3. DEVCONSOLE_REPO inconnu → erreur
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="sync"
for arg in "$@"; do
    case "$arg" in
        --check) MODE="check" ;;
        *) echo "Argument inconnu: $arg" >&2; exit 2 ;;
    esac
done

# ─── Localisation du repo DevConsole ────────────────────────────────────────
if [ -n "${DEVCONSOLE_REPO:-}" ]; then
    DC_REPO="$DEVCONSOLE_REPO"
elif [ -d "$ROOT/../.git" ]; then
    # Le registry est dans le workspace DevConsole (devconsole-registry/)
    DC_REPO="$(cd "$ROOT/.." && pwd)"
else
    echo "❌ Repo DevConsole introuvable — définissez DEVCONSOLE_REPO" >&2
    exit 1
fi

SRC="$ROOT/versions.json"
DST="$DC_REPO/src-tauri/resources/versions.json"

if [ ! -f "$SRC" ]; then
    echo "❌ $SRC introuvable" >&2
    exit 1
fi
if [ ! -d "$DC_REPO/.git" ]; then
    echo "❌ $DC_REPO n'est pas un dépôt git" >&2
    exit 1
fi

# ─── Comparaison ─────────────────────────────────────────────────────────────
# Normalise JSON (tri des clés, pas de dépendance à jq) pour comparer le
# contenu sémantique, pas la mise en forme.
norm() {
    "$PY" -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True, indent=1))' "$1"
}
PY=python3
command -v "$PY" >/dev/null 2>&1 || PY=python

if [ ! -f "$DST" ]; then
    echo "⚠️  $DST absent — l'embarquée n'existe pas" >&2
    if [ "$MODE" = "check" ]; then exit 1; fi
    cp "$SRC" "$DST"
    echo "✅ Créé $DST"
    exit 0
fi

if [ "$MODE" = "check" ]; then
    if [ "$(norm "$SRC")" = "$(norm "$DST")" ]; then
        echo "✓ Registry embarqué à jour"
        exit 0
    fi
    echo "⚠️  Registry embarqué en retard ($DST)"
    echo "   Lancez : scripts/sync-embedded-registry.sh"
    exit 1
fi

# ─── Sync (copie seule — le commit est laissé au user) ──────────────────────
cp "$SRC" "$DST"
echo "✅ Embarquée synchronisée : $DST"
echo "→ Committez dans $DC_REPO avec votre message métier :"
echo "    git -C $DC_REPO add src-tauri/resources/versions.json"
echo "    git -C $DC_REPO commit -m \"<message>\""
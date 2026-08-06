#!/bin/sh
# Verrou anti double-build (CI GitHub self-hosted / build local sur la même machine).
# Empêche deux compilations cargo/npm simultanées qui saturaient la machine et
# faisaient échouer CI et builds locaux en même temps.
#
# Usage :
#   scripts/build-lock.sh <commande> [args...]
#
# Comportement :
#   - Défaut (build local) : échoue immédiatement si un autre build est en cours.
#   - BUILD_LOCK_WAIT=1 (CI) : attend la libération du verrou, avec un délai max
#     de BUILD_LOCK_TIMEOUT secondes (défaut 1800 = 30 min).
#
# Le verrou utilise flock(1) : il est automatiquement libéré si le processus
# meurt (aucun verrou obsolète en cas de crash).
set -u

LOCK_FILE="${DEVCONSOLE_BUILD_LOCK:-$HOME/.devconsole-build.lock}"
# Code de sortie interne pour distinguer "verrou non acquis" d'un échec de la
# commande elle-même (flock propage le statut de la commande exécutée).
LOCK_FAILED=99

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <commande> [args...]" >&2
    exit 2
fi

mkdir -p "$(dirname "$LOCK_FILE")"

# L'acquisition du verrou (fd 9) et l'exécution sont séparées : le statut de
# sortie remonté est celui de la commande, pas celui de flock.
if [ "${BUILD_LOCK_WAIT:-0}" = "1" ]; then
    timeout_s="${BUILD_LOCK_TIMEOUT:-1800}"
    (
        if ! flock -w "$timeout_s" 9; then
            echo "*** CI : un build local tient le verrou depuis plus de ${timeout_s}s, abandon." >&2
            exit $LOCK_FAILED
        fi
        "$@"
        exit $?
    ) 9>"$LOCK_FILE"
    status=$?
    if [ "$status" -eq "$LOCK_FAILED" ]; then
        exit 1
    fi
    exit "$status"
fi

(
    if ! flock -n 9; then
        echo "*** Build impossible : un autre build est déjà en cours" >&2
        echo "*** (CI GitHub self-hosted ou build local sur cette machine)." >&2
        echo "*** Attendez la fin du build en cours, ou : rm -f \"$LOCK_FILE\"" >&2
        exit $LOCK_FAILED
    fi
    "$@"
    exit $?
) 9>"$LOCK_FILE"
status=$?
if [ "$status" -eq "$LOCK_FAILED" ]; then
    exit 1
fi
exit "$status"

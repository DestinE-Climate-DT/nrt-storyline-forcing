#!/usr/bin/env bash
# Prepare this clone to run: runtime directories, the pixi env, and nrt_forcing.conf.
#
#   nrt_forcing_setup.sh --site NAME --account SLURM_ACCOUNT
#
# Re-runnable: an existing nrt_forcing.conf is never overwritten.
# Exit codes: 0 ready, 1 bad arguments or a failed step, 3 no sites/NAME.conf.

set -uo pipefail

usage() {
    echo "usage: nrt_forcing_setup.sh --site NAME --account SLURM_ACCOUNT" >&2
    exit 1
}

SITE=""
ACCOUNT=""
while [ $# -gt 0 ]; do
    case $1 in
    --site)
        SITE=${2:-}
        shift 2 || usage
        ;;
    --account)
        ACCOUNT=${2:-}
        shift 2 || usage
        ;;
    *) usage ;;
    esac
done
[ -n "${SITE}" ] && [ -n "${ACCOUNT}" ] || usage

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ ! -f "${ROOT}/sites/${SITE}.conf" ]; then
    echo "ERROR: no sites/${SITE}.conf" >&2
    exit 3
fi
# shellcheck source=/dev/null
. "${ROOT}/sites/${SITE}.conf"
PATH=${NRT_PIXI_BIN:+${NRT_PIXI_BIN}:}${PATH}

# A umask of 0077 would lock the rest of the project out of the forcing.
mkdir -p "${ROOT}/inproot/storyline_forcing" "${ROOT}/logs" || exit 1
chmod 2755 "${ROOT}" "${ROOT}/inproot" "${ROOT}/inproot/storyline_forcing" "${ROOT}/logs"
# The site may put CDO's intermediates off the node's own $TMPDIR.
[ -z "${NRT_TMPDIR:-}" ] || mkdir -p "${NRT_TMPDIR}" || exit 1

# A missing CLI otherwise reads as a broken env and the recovery below moves it aside.
if ! command -v pixi >/dev/null 2>&1; then
    echo "ERROR: no pixi on PATH; NRT_PIXI_BIN is '${NRT_PIXI_BIN:-unset}'" >&2
    exit 1
fi

env_ok() {
    pixi run --manifest-path "${ROOT}/pixi.toml" snakemake --version >/dev/null 2>&1
}
if env_ok; then
    echo "pixi env ready"
else
    # `pixi install` does not repair a moved env (its shebangs keep the old prefix), so solve afresh.
    if [ -d "${ROOT}/.pixi" ]; then
        broken=${ROOT}/.pixi.broken-$(date -u +%Y%m%dT%H%M%SZ)
        echo "env not runnable, moving it to ${broken}"
        mv "${ROOT}/.pixi" "${broken}" || exit 1
    fi
    pixi install --manifest-path "${ROOT}/pixi.toml" || exit 1
    if ! env_ok; then
        echo "ERROR: snakemake still not runnable from ${ROOT}/pixi.toml" >&2
        exit 1
    fi
fi

CONF=${ROOT}/nrt_forcing.conf
if [ -f "${CONF}" ]; then
    echo "config present, left alone: ${CONF}"
else
    sed -e "s|^NRT_SITE=.*|NRT_SITE=${SITE}|" -e "s|^NRT_SLURM_ACCOUNT=.*|NRT_SLURM_ACCOUNT=${ACCOUNT}|" \
        "${ROOT}/nrt_forcing.conf.example" >"${CONF}" || exit 1
    echo "wrote ${CONF}; set NRT_DEST_HOST if the destination is another machine"
fi
if [ -x "${ROOT}/nrt_forcing_check.sh" ]; then
    echo "checking this machine:"
    "${ROOT}/nrt_forcing_check.sh" || exit 1
fi
echo "ready: ${ROOT}"

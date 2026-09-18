#!/usr/bin/env bash
# Check that this machine can run the producer, before a real day depends on it.
#
#   nrt_forcing_check.sh [--config FILE]
#
# A machine is supported when this passes and one known day is byte-identical
# to a reference. Exit codes: 0 all checks pass, 1 at least one failed,
# 3 config or site file missing.

set -uo pipefail

CONF=${NRT_FORCING_CONF:-}
while [ $# -gt 0 ]; do
    case $1 in
    --config)
        CONF=${2:-}
        shift 2 || exit 1
        ;;
    *)
        echo "usage: nrt_forcing_check.sh [--config FILE]" >&2
        exit 1
        ;;
    esac
done

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONF=${CONF:-${ROOT}/nrt_forcing.conf}
if [ ! -f "${CONF}" ]; then
    echo "ERROR: no config ${CONF}; run nrt_forcing_setup.sh" >&2
    exit 3
fi
# shellcheck source=/dev/null
. "${CONF}" || exit 3
SITE_FILE=${ROOT}/sites/${NRT_SITE:-}.conf
if [ -z "${NRT_SITE:-}" ] || [ ! -f "${SITE_FILE}" ]; then
    echo "ERROR: ${CONF} needs an NRT_SITE with a sites/<name>.conf" >&2
    exit 3
fi
# shellcheck source=/dev/null
. "${SITE_FILE}" || exit 3
PATH=${NRT_PIXI_BIN:+${NRT_PIXI_BIN}:}${PATH}

FAILED=0
ok() { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
bad() {
    printf '  FAIL  %s\n' "$*"
    FAILED=1
}

echo "site ${NRT_SITE}, clone ${ROOT}"

# 1. The environment, tested by running it rather than by looking for .pixi.
if pixi run --manifest-path "${ROOT}/pixi.toml" snakemake --version >/dev/null 2>&1; then
    ok "pixi env runs snakemake"
else
    bad "pixi env cannot run snakemake; run nrt_forcing_setup.sh"
fi

# 2. Everything the driver and the rule shell out to.
for tool in rsync grib_get cdo; do
    if pixi run --manifest-path "${ROOT}/pixi.toml" "${tool}" --version >/dev/null 2>&1 ||
        command -v "${tool}" >/dev/null 2>&1; then
        ok "${tool} available"
    else
        bad "${tool} not found"
    fi
done
if stat -c %s "${ROOT}" >/dev/null 2>&1 && date -u -d '20170101 + 1 day' >/dev/null 2>&1; then
    ok "GNU stat and date"
else
    bad "GNU stat -c / date -d needed; this is not a GNU userland"
fi

# 3. An inode quota is what a pixi env in the wrong filesystem runs into.
case ${ROOT} in
"${HOME}"/*) warn "clone is under \$HOME; a pixi env is ~45k inodes, so check the home file quota" ;;
*) ok "clone is outside \$HOME" ;;
esac

# 4. A POSIX group is not a scheduler association.
if [ -n "${NRT_SLURM_PARTITION:-}" ]; then
    if command -v sinfo >/dev/null 2>&1; then
        if [ -n "$(sinfo -h -p "${NRT_SLURM_PARTITION}" -o %P 2>/dev/null)" ]; then
            ok "partition ${NRT_SLURM_PARTITION} exists"
        else
            bad "no partition ${NRT_SLURM_PARTITION} on this machine"
        fi
        if [ -z "${NRT_SLURM_ACCOUNT:-}" ]; then
            bad "${CONF} sets no NRT_SLURM_ACCOUNT"
        elif [ -n "$(sacctmgr -nP show assoc user="$(id -un)" account="${NRT_SLURM_ACCOUNT}" 2>/dev/null)" ]; then
            ok "account ${NRT_SLURM_ACCOUNT} has an association for $(id -un)"
        else
            bad "no SLURM association for $(id -un) on ${NRT_SLURM_ACCOUNT}; jobs will not run"
        fi
    else
        warn "no sinfo here; the scheduler cannot be checked"
    fi
fi

# 5. Where ERA5 comes from, asked of the source itself.
ERA5_SOURCE=${NRT_ERA5_SOURCE:-$(sed -n 's/^era5_source: *//p' "${ROOT}/producer/${NRT_PRODUCER_CONFIG}" 2>/dev/null)}
ERA5_DIR=${NRT_ERA5_DIR:-$(sed -n 's/^dir_era5: *//p' "${ROOT}/producer/${NRT_PRODUCER_CONFIG}" 2>/dev/null)}
if [ "${ERA5_SOURCE:-}" = cds ]; then
    rc=${HOME}/.cdsapirc
    if [ ! -f "${rc}" ]; then
        bad "era5_source is cds but there is no ~/.cdsapirc"
    else
        if grep -q '^url:' "${rc}" && grep -q '^key:' "${rc}"; then
            ok "~/.cdsapirc has a url and a credential"
        else
            bad "~/.cdsapirc is missing its url or credential line"
        fi
        mode=$(stat -c %a "${rc}" 2>/dev/null)
        case ${mode} in
        *00) ok "~/.cdsapirc is owner-only" ;;
        *) warn "~/.cdsapirc is mode ${mode}, readable beyond its owner" ;;
        esac
        # The client owns the credential, so it does the loading; this never reads it.
        if pixi run --manifest-path "${ROOT}/pixi.toml" python -c 'import cdsapi; cdsapi.Client()' >/dev/null 2>&1; then
            ok "cdsapi accepts ~/.cdsapirc"
        else
            bad "cdsapi cannot use ~/.cdsapirc"
        fi
        # Entitlement is per dataset and only a real retrieval proves it; see the README.
        code=$(curl -s -o /dev/null -m 30 -w '%{http_code}' \
            https://cds.climate.copernicus.eu/api/retrieve/v1/processes 2>/dev/null)
        case ${code} in
        000 | "") warn "CDS did not answer; check egress from this node" ;;
        *) ok "CDS reachable (${code}); entitlement is proven by the first retrieval, not here" ;;
        esac
    fi
    [ -d "${ERA5_DIR:-}" ] && ok "ERA5 cache ${ERA5_DIR}" || warn "ERA5 cache ${ERA5_DIR:-<unset>} does not exist yet"
elif [ -d "${ERA5_DIR:-}" ]; then
    ok "ERA5 pool ${ERA5_DIR}"
else
    bad "no ERA5 source: dir_era5 ${ERA5_DIR:-<unset>} is not a directory and era5_source is not cds"
fi

# 6. A tmpfs $TMPDIR is charged to the job's own memory, so say where it is.
TMP=${NRT_TMPDIR:-}
if [ -z "${TMP}" ]; then
    warn "no NRT_TMPDIR; CDO uses the node's own \$TMPDIR, which may be a tmpfs"
elif mkdir -p "${TMP}" 2>/dev/null && [ -w "${TMP}" ]; then
    ok "tmpdir ${TMP}, $(df -h "${TMP}" 2>/dev/null | awk 'NR==2 {print $4}') free"
else
    bad "tmpdir ${TMP} is not writable"
fi

# 7. The destination, when it is another machine.
if [ -n "${NRT_DEST_HOST:-}" ]; then
    if ssh -o BatchMode=yes -o ConnectTimeout=30 "${NRT_DEST_HOST}" true 2>/dev/null; then
        ok "dest host ${NRT_DEST_HOST} answers"
    else
        bad "dest host ${NRT_DEST_HOST} does not answer with BatchMode"
    fi
else
    ok "destination is this machine"
fi

[ "${FAILED}" = 0 ] && echo "ready" || echo "not ready" >&2
exit "${FAILED}"

#!/usr/bin/env bash
# Produce storyline nudging forcing, verify each day, and ship it to the directory the release probes.
#
#   nrt_forcing.sh --dest-dir DIR [--dest-host HOST] [--plan] [--no-sync] [--expid ID]
#                  [--config FILE] <FIRST_DAY> <LAST_DAY>
#
# Exit codes:
#   0   produced, and shipped unless --no-sync
#   1   bad arguments, including a DIR that does not end in tco<N>l137, or an
#       absolute DIR whose root is not on this machine and no dest host
#   3   config, site file or producer missing
#   4   Snakemake refused the request or failed
#   5   a day failed verification
#   6   a verified day did not reach the destination intact
#   10  --plan found nothing to do, or a run is already in progress

set -uo pipefail

usage() {
    echo "usage: nrt_forcing.sh --dest-dir DIR [--dest-host HOST] [--plan]" \
        "[--no-sync] [--expid ID] [--config FILE] <FIRST_DAY> <LAST_DAY>" >&2
    exit 1
}

CONF=${NRT_FORCING_CONF:-}
DEST_DIR=""
DEST_HOST_ARG=""
PLAN_ONLY=0
SYNC=1
EXPID=${NRT_EXPID:-}
while [ $# -gt 0 ]; do
    case $1 in
    --dest-dir)
        DEST_DIR=${2:-}
        shift 2 || usage
        ;;
    --dest-host)
        DEST_HOST_ARG=${2:-}
        shift 2 || usage
        ;;
    --config)
        CONF=${2:-}
        shift 2 || usage
        ;;
    --expid)
        EXPID=${2:-}
        shift 2 || usage
        ;;
    --plan)
        PLAN_ONLY=1
        shift
        ;;
    --no-sync)
        SYNC=0
        shift
        ;;
    --help | -h) usage ;;
    --*)
        echo "ERROR: unknown option $1" >&2
        usage
        ;;
    *) break ;;
    esac
done
[ $# -eq 2 ] || usage
FIRST_DAY=$1
LAST_DAY=$2

GRID=$(basename "${DEST_DIR:-/}")
if ! [[ ${GRID} =~ ^tco([0-9]+)l137$ ]]; then
    echo "ERROR: --dest-dir must end in tco<N>l137 (got '${DEST_DIR}')" >&2
    exit 1
fi
RESOLUTION=tco${BASH_REMATCH[1]}
for day in "${FIRST_DAY}" "${LAST_DAY}"; do
    if ! [[ ${day} =~ ^[0-9]{8}$ ]]; then
        echo "ERROR: days must be YYYYMMDD (got '${day}')" >&2
        exit 1
    fi
done
if [ "${LAST_DAY}" -lt "${FIRST_DAY}" ]; then
    echo "ERROR: LAST_DAY ${LAST_DAY} precedes FIRST_DAY ${FIRST_DAY}" >&2
    exit 1
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONF=${CONF:-${ROOT}/nrt_forcing.conf}
if [ ! -f "${CONF}" ]; then
    echo "ERROR: no config ${CONF}; run nrt_forcing_setup.sh" >&2
    exit 3
fi
# shellcheck source=/dev/null
. "${CONF}" || exit 3
SITE_FILE=${ROOT}/sites/${NRT_SITE:-}.conf
if [ -z "${NRT_SITE:-}" ] || [ ! -f "${SITE_FILE}" ] || [ -z "${NRT_SLURM_ACCOUNT:-}" ]; then
    echo "ERROR: ${CONF} needs NRT_SLURM_ACCOUNT and an NRT_SITE with a sites/<name>.conf" >&2
    exit 3
fi
# shellcheck source=/dev/null
. "${SITE_FILE}" || exit 3

DEST_HOST=${DEST_HOST_ARG:-${NRT_DEST_HOST:-}}

# No dest host means "ship to this machine". If an absolute --dest-dir's root
# is not here, that silently becomes a local mkdir of someone else's path and
# nothing is ever shipped, so refuse before spending the produce.
if [ -z "${DEST_HOST}" ] && [ "${DEST_DIR#/}" != "${DEST_DIR}" ]; then
    dest_root=${DEST_DIR#/}
    dest_root=/${dest_root%%/*}
    if [ ! -d "${dest_root}" ]; then
        echo "ERROR: no dest host, and ${dest_root} is not on this machine;" \
            "pass --dest-host or set NRT_DEST_HOST in ${CONF}" >&2
        exit 1
    fi
fi

JOBS=${NRT_SNAKEMAKE_JOBS:-10}
TMPDIR_OVERRIDE=${NRT_TMPDIR:-}
OUTDIR=${ROOT}/inproot/storyline_forcing/${GRID}
LOG_DIR=${ROOT}/logs/${GRID}
PATH=${NRT_PIXI_BIN:+${NRT_PIXI_BIN}:}${PATH}
VERSION=$(git -C "${ROOT}" describe --tags --always --dirty 2>/dev/null || echo unknown)

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
START_EPOCH=$(date -u +%s)
RUN_USER=$(id -un)
RUN_HOST=$(hostname -s)
# SSH_CLIENT is set when a cron tick reached us over ssh, unset in a login shell.
CALLER=${SSH_CLIENT:+ssh:${SSH_CLIENT%% *}}
CALLER=${CALLER:-local}
MODE=produce
[ "${PLAN_ONLY}" = 1 ] && MODE=plan
[ "${SYNC}" = 0 ] && MODE=${MODE}+nosync
mkdir -p "${LOG_DIR}" || exit 3
EVENTS=${LOG_DIR}/events.jsonl
PROM=${LOG_DIR}/nrt_forcing.prom
LOGFILE=${LOG_DIR}/${FIRST_DAY}_${LAST_DAY}_${RUN_ID}.log
exec > >(tee -a "${LOGFILE}") 2>&1

DAYS_PRODUCED=0
DAYS_VERIFIED=0
DAYS_SHIPPED=0
DAYS_LANDED=0
LAST_SHIPPED_DAY=0
RECORD_BYTES=0

# One flat JSON object per line, identity on every line, so Loki needs no parser stage.
log_event() {
    local event=$1 extra=""
    shift
    while [ $# -gt 0 ]; do
        extra="${extra},\"$1\":$2"
        shift 2
    done
    printf '{"ts":"%s","run_id":"%s","event":"%s","expid":"%s","resolution":"%s","grid":"%s","first_day":"%s","last_day":"%s","user":"%s","host":"%s"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RUN_ID}" "${event}" "${EXPID}" "${RESOLUTION}" \
        "${GRID}" "${FIRST_DAY}" "${LAST_DAY}" "${RUN_USER}" "${RUN_HOST}" "${extra}" >>"${EVENTS}"
}

# Prometheus textfile gauges, written via a temp file so the collector never reads a partial file.
write_metrics() {
    local rc=$1 now lbl
    now=$(date -u +%s)
    lbl="resolution=\"${RESOLUTION}\",expid=\"${EXPID}\",grid=\"${GRID}\""
    {
        echo "# HELP nrt_forcing_last_run_timestamp_seconds Unix time the driver last ran."
        echo "# TYPE nrt_forcing_last_run_timestamp_seconds gauge"
        echo "nrt_forcing_last_run_timestamp_seconds{${lbl}} ${now}"
        echo "# HELP nrt_forcing_run_duration_seconds Wall time of the last run."
        echo "# TYPE nrt_forcing_run_duration_seconds gauge"
        echo "nrt_forcing_run_duration_seconds{${lbl}} $((now - START_EPOCH))"
        echo "# HELP nrt_forcing_exit_code Exit code of the last run."
        echo "# TYPE nrt_forcing_exit_code gauge"
        echo "nrt_forcing_exit_code{${lbl}} ${rc}"
        echo "# HELP nrt_forcing_days Days by stage in the last run."
        echo "# TYPE nrt_forcing_days gauge"
        echo "nrt_forcing_days{${lbl},stage=\"produced\"} ${DAYS_PRODUCED}"
        echo "nrt_forcing_days{${lbl},stage=\"verified\"} ${DAYS_VERIFIED}"
        echo "nrt_forcing_days{${lbl},stage=\"shipped\"} ${DAYS_SHIPPED}"
        echo "nrt_forcing_days{${lbl},stage=\"landed\"} ${DAYS_LANDED}"
        echo "# HELP nrt_forcing_record_bytes Size of one forcing record."
        echo "# TYPE nrt_forcing_record_bytes gauge"
        echo "nrt_forcing_record_bytes{${lbl}} ${RECORD_BYTES}"
        if [ "${LAST_SHIPPED_DAY}" -gt 0 ]; then
            echo "# HELP nrt_forcing_last_shipped_day Newest day confirmed at the destination, YYYYMMDD."
            echo "# TYPE nrt_forcing_last_shipped_day gauge"
            echo "nrt_forcing_last_shipped_day{${lbl}} ${LAST_SHIPPED_DAY}"
            echo "# HELP nrt_forcing_last_success_timestamp_seconds Unix time a day last reached the destination."
            echo "# TYPE nrt_forcing_last_success_timestamp_seconds gauge"
            echo "nrt_forcing_last_success_timestamp_seconds{${lbl}} ${now}"
        elif [ -f "${PROM}" ]; then
            # Carry freshness forward, or every quiet tick looks like an outage.
            grep -E '^nrt_forcing_(last_shipped_day|last_success_timestamp_seconds)' "${PROM}"
        fi
    } >"${PROM}.tmp" && mv "${PROM}.tmp" "${PROM}"
}

on_exit() {
    local rc=$?
    log_event end rc "${rc}" duration_seconds "$(($(date -u +%s) - START_EPOCH))"
    write_metrics "${rc}"
    # An idle plan is the common tick; events.jsonl records it, a log file per tick would not add anything.
    if [ "${PLAN_ONLY}" = 1 ] && [ "${rc}" -eq 10 ]; then
        rm -f "${LOGFILE}"
    fi
}
trap on_exit EXIT

if ! cd "${ROOT}/producer" 2>/dev/null || [ ! -f workflow/Snakefile ]; then
    echo "ERROR: no producer in ${ROOT}/producer" >&2
    exit 3
fi
# stderr stays out of the hook: pixi warns there (e.g. a cache on Lustre), and eval would choke on it.
if ! hook=$(pixi shell-hook --manifest-path "${ROOT}/pixi.toml") || ! eval "${hook}"; then
    echo "ERROR: pixi env not usable; run nrt_forcing_setup.sh" >&2
    exit 3
fi

TARGETS=()
DAYS=()
day=${FIRST_DAY}
while [ "${day}" -le "${LAST_DAY}" ]; do
    TARGETS+=("${OUTDIR}/rlxmlsh${day}"{00,06,12,18}"00")
    DAYS+=("${day}")
    day=$(date -u -d "${day} + 1 day" +%Y%m%d) || exit 1
done

SNAKEMAKE=(snakemake
    --profile "${NRT_SNAKEMAKE_PROFILE}"
    --configfile "${NRT_PRODUCER_CONFIG}"
    --config "inproot=${ROOT}/inproot" ${NRT_CDO:+"cdo=${NRT_CDO}"}
    --default-resources "slurm_account=${NRT_SLURM_ACCOUNT}" "slurm_partition=${NRT_SLURM_PARTITION}")
if [ -n "${TMPDIR_OVERRIDE}" ]; then
    SNAKEMAKE+=("tmpdir='${TMPDIR_OVERRIDE}'")
fi
# --jobs closes the --default-resources list; left open it swallows the targets, and --plan cannot show it.
SNAKEMAKE+=(--jobs "${JOBS}")

log_event start \
    root "\"${ROOT}\"" outdir "\"${OUTDIR}\"" dest_host "\"${DEST_HOST}\"" dest_dir "\"${DEST_DIR}\"" \
    config "\"${CONF}\"" mode "\"${MODE}\"" caller "\"${CALLER}\"" \
    driver_version "\"${VERSION}\"" days "${#DAYS[@]}" jobs "${JOBS}" pid "$$"

echo "=============================================================="
echo " NRT storyline forcing"
echo "   run_id     ${RUN_ID}   (driver ${VERSION}, mode ${MODE})"
echo "   expid      ${EXPID:-<none: not driven by an experiment>}"
echo "   days       ${FIRST_DAY}..${LAST_DAY}  (${#DAYS[@]})"
echo "   grid       ${GRID}"
echo "   who        ${RUN_USER}@${RUN_HOST}  caller ${CALLER}"
echo "   config     ${CONF}  site ${NRT_SITE}"
echo "   out        ${OUTDIR}"
echo "   dest       ${DEST_HOST:+${DEST_HOST}:}${DEST_DIR}"
echo "=============================================================="

if [ -n "$(ls -A .snakemake/locks 2>/dev/null)" ]; then
    log_event already_running
    exit 10
fi

if ! plan=$("${SNAKEMAKE[@]}" --dry-run "${TARGETS[@]}" 2>&1); then
    log_event plan_refused
    printf '%s\n' "${plan}" | tail -30
    exit 4
fi
case ${plan} in
*"Nothing to be done"*)
    log_event nothing_to_do
    [ "${PLAN_ONLY}" = 1 ] && exit 10
    ;;
*)
    printf '%s\n' "${plan}" | tail -15
    [ "${PLAN_ONLY}" = 1 ] && exit 0
    if ! "${SNAKEMAKE[@]}" "${TARGETS[@]}"; then
        log_event produce_failed
        echo "ERROR: Snakemake failed for ${FIRST_DAY}..${LAST_DAY}" >&2
        exit 4
    fi
    DAYS_PRODUCED=${#DAYS[@]}
    log_event produced days "${DAYS_PRODUCED}"
    ;;
esac

# Four records sharing one non-zero size: the rule the release probe applies.
day_complete() {
    local sizes
    sizes=$(stat -c %s "$1/rlxmlsh$2"{00,06,12,18}00 2>/dev/null) || return 1
    [[ $(sort -u <<<"${sizes}") =~ ^[1-9][0-9]*$ ]]
}

# The probe's rule, plus each record holding its own hour: a copy of 00 UTC passes the size rule.
verify_day() {
    local day=$1 hh
    if ! day_complete "${OUTDIR}" "${day}"; then
        echo "  ${day}: not four records of one non-zero size" >&2
        return 1
    fi
    for hh in 00 06 12 18; do
        if ! [ "$(grib_get -w count=1 -p dataTime "${OUTDIR}/rlxmlsh${day}${hh}00")" -eq "$((10#${hh}00))" ] 2>/dev/null; then
            echo "  ${day}: rlxmlsh${day}${hh}00 does not hold ${hh} UTC" >&2
            return 1
        fi
    done
    RECORD_BYTES=$(stat -c %s "${OUTDIR}/rlxmlsh${day}0000")
    echo "  ${day}: 4 records, ${RECORD_BYTES} B each"
}

# Runs stdin as a bash script on the destination machine.
on_dest() {
    if [ -n "${DEST_HOST}" ]; then
        ssh -o BatchMode=yes "${DEST_HOST}" bash -s
    else
        bash -s
    fi
}

echo "verifying:"
verified=()
rc=0
for day in "${DAYS[@]}"; do
    if verify_day "${day}"; then
        verified+=("${day}")
        log_event verified day "\"${day}\"" bytes "${RECORD_BYTES}"
    else
        log_event verify_failed day "\"${day}\""
        rc=5
    fi
done
DAYS_VERIFIED=${#verified[@]}
if [ "${DAYS_VERIFIED}" -eq 0 ]; then
    echo "ERROR: no day passed verification" >&2
    exit 5
fi
if [ "${SYNC}" = 0 ]; then
    echo "produced: ${verified[*]}"
    exit "${rc}"
fi

if ! on_dest <<<"mkdir -p '${DEST_DIR}'" >/dev/null 2>&1; then
    echo "ERROR: cannot create ${DEST_HOST:+${DEST_HOST}:}${DEST_DIR}" >&2
    exit 6
fi
shipped=()
for day in "${verified[@]}"; do
    # --partial-dir keeps a torn record out of the directory the probe lists.
    # --chmod overrides the producer's inherited mode, which can leave the
    # records unreadable to the account that runs the experiment.
    if rsync -a --chmod=F644 --partial-dir=.rsync-partial \
        "${OUTDIR}/rlxmlsh${day}"{00,06,12,18}00 \
        "${DEST_HOST:+${DEST_HOST}:}${DEST_DIR}/"; then
        shipped+=("${day}")
        DAYS_SHIPPED=$((DAYS_SHIPPED + 1))
        log_event shipped day "\"${day}\""
    else
        log_event ship_failed day "\"${day}\""
        echo "  ${day}: TRANSFER FAILED" >&2
        rc=6
    fi
done
if [ "${DAYS_SHIPPED}" -eq 0 ]; then
    echo "shipped: none"
    exit "${rc}"
fi

# rsync exiting 0 means bytes were sent, not that the probe will accept the day.
landed=$(on_dest <<<"$(declare -f day_complete)
for d in ${shipped[*]}; do day_complete '${DEST_DIR}' \$d && echo \$d; done")
for day in "${shipped[@]}"; do
    if grep -qx "${day}" <<<"${landed}"; then
        DAYS_LANDED=$((DAYS_LANDED + 1))
        [ "${day}" -gt "${LAST_SHIPPED_DAY}" ] && LAST_SHIPPED_DAY=${day}
        log_event landed day "\"${day}\""
    else
        log_event land_failed day "\"${day}\""
        echo "  ${day}: did not land as four records of one size" >&2
        rc=6
    fi
done
echo "shipped: ${landed//$'\n'/ }"
exit "${rc}"

# Driver interface: exit codes, grid derivation, verification, shipping.

setup() {
    ROOT=${BATS_TEST_TMPDIR}/clone
    mkdir -p "${ROOT}/producer/workflow" "${ROOT}/sites"
    cp "${BATS_TEST_DIRNAME}/../nrt_forcing.sh" "${ROOT}/"
    cp "${BATS_TEST_DIRNAME}/../sites/levante.conf" "${ROOT}/sites/"
    touch "${ROOT}/producer/workflow/Snakefile"
    MOCKS=${BATS_TEST_DIRNAME}/mocks
    printf 'NRT_SITE=levante\nNRT_SLURM_ACCOUNT=acct\nNRT_PIXI_BIN=%s\n' "${MOCKS}" >"${ROOT}/nrt_forcing.conf"
    PATH=${MOCKS}:${PATH}
    DEST=${BATS_TEST_TMPDIR}/dest/tco79l137
    OUT=${ROOT}/inproot/storyline_forcing/tco79l137
    LOGS=${ROOT}/logs/tco79l137
}

records() {
    mkdir -p "${OUT}"
    for hh in 00 06 12 18; do
        printf '%08d' 0 >"${OUT}/rlxmlsh$1${hh}00"
    done
}

@test "no config: 3" {
    rm "${ROOT}/nrt_forcing.conf"
    run "${ROOT}/nrt_forcing.sh" --dest-dir "${DEST}" 20170101 20170101
    [ "${status}" -eq 3 ]
}

@test "NRT_SITE without a site file: 3" {
    echo NRT_SITE=nowhere >>"${ROOT}/nrt_forcing.conf"
    run "${ROOT}/nrt_forcing.sh" --dest-dir "${DEST}" 20170101 20170101
    [ "${status}" -eq 3 ]
}

@test "dest dir that is not tco<N>l137: 1" {
    run "${ROOT}/nrt_forcing.sh" --dest-dir "${BATS_TEST_TMPDIR}/tco79l60" 20170101 20170101
    [ "${status}" -eq 1 ]
}

@test "no dest dir: 1" {
    run "${ROOT}/nrt_forcing.sh" 20170101 20170101
    [ "${status}" -eq 1 ]
}

@test "pixi hook that does not evaluate: 3" {
    MOCK_BAD_HOOK=1 run "${ROOT}/nrt_forcing.sh" --plan --dest-dir "${DEST}" 20170101 20170101
    [ "${status}" -eq 3 ]
}

@test "idle plan: 10 and no run log left" {
    records 20170101
    run "${ROOT}/nrt_forcing.sh" --plan --dest-dir "${DEST}" 20170101 20170101
    [ "${status}" -eq 10 ]
    [ -z "$(find "${LOGS}" -name '*.log')" ]
    grep -q '"event":"end"' "${LOGS}/events.jsonl"
}

@test "missing day, plan: 0" {
    run "${ROOT}/nrt_forcing.sh" --plan --dest-dir "${DEST}" 20170101 20170101
    [ "${status}" -eq 0 ]
    [ ! -e "${OUT}/rlxmlsh201701010000" ]
}

@test "missing day produced with NRT_TMPDIR set: targets still follow --jobs" {
    NRT_TMPDIR=${BATS_TEST_TMPDIR}/tmp run "${ROOT}/nrt_forcing.sh" --dest-dir "${DEST}" 20170101 20170102
    [ "${status}" -eq 0 ]
    [ "$(find "${DEST}" -name 'rlxmlsh*' | wc -l)" -eq 8 ]
}

@test "snakemake fails: 4" {
    MOCK_SNAKEMAKE_RC=1 run "${ROOT}/nrt_forcing.sh" --dest-dir "${DEST}" 20170101 20170101
    [ "${status}" -eq 4 ]
}

@test "06 record holding 00 UTC: 5" {
    records 20170101
    MOCK_BAD_DATATIME=rlxmlsh201701010600 run "${ROOT}/nrt_forcing.sh" --dest-dir "${DEST}" 20170101 20170101
    [ "${status}" -eq 5 ]
}

@test "one record of another size: 5" {
    records 20170101
    printf 'x' >>"${OUT}/rlxmlsh201701011200"
    run "${ROOT}/nrt_forcing.sh" --dest-dir "${DEST}" 20170101 20170101
    [ "${status}" -eq 5 ]
}

@test "one empty record beside three equal ones: 5" {
    records 20170101
    : >"${OUT}/rlxmlsh201701011800"
    run "${ROOT}/nrt_forcing.sh" --dest-dir "${DEST}" 20170101 20170101
    [ "${status}" -eq 5 ]
}

@test "transfer fails: 6" {
    records 20170101
    MOCK_RSYNC_RC=1 run "${ROOT}/nrt_forcing.sh" --dest-dir "${DEST}" 20170101 20170101
    [ "${status}" -eq 6 ]
}

@test "remote destination: lands, then an idle plan keeps the freshness gauges" {
    echo NRT_DEST_HOST=dest-host >>"${ROOT}/nrt_forcing.conf"
    records 20170101
    run "${ROOT}/nrt_forcing.sh" --dest-dir "${DEST}" 20170101 20170101
    [ "${status}" -eq 0 ]
    grep -q '"event":"landed"' "${LOGS}/events.jsonl"
    run "${ROOT}/nrt_forcing.sh" --plan --dest-dir "${DEST}" 20170101 20170101
    [ "${status}" -eq 10 ]
    grep -q '^nrt_forcing_last_shipped_day{.*} 20170101$' "${LOGS}/nrt_forcing.prom"
}

@test "two grids from one clone keep separate logs" {
    run "${ROOT}/nrt_forcing.sh" --plan --dest-dir "${DEST}" 20170101 20170101
    run "${ROOT}/nrt_forcing.sh" --plan --dest-dir "${BATS_TEST_TMPDIR}/dest/tco1279l137" 20170101 20170101
    [ -f "${LOGS}/events.jsonl" ]
    [ -f "${ROOT}/logs/tco1279l137/events.jsonl" ]
}

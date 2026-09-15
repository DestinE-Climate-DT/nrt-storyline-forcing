# Setup: arguments, config written once and never overwritten, a broken env moved aside.

setup() {
    ROOT=${BATS_TEST_TMPDIR}/clone
    mkdir -p "${ROOT}/sites"
    cp "${BATS_TEST_DIRNAME}/../nrt_forcing_setup.sh" "${BATS_TEST_DIRNAME}/../nrt_forcing.conf.example" "${ROOT}/"
    cp "${BATS_TEST_DIRNAME}/../sites/levante.conf" "${ROOT}/sites/"
    export NRT_PIXI_BIN=${BATS_TEST_DIRNAME}/mocks
}

@test "missing --account: 1" {
    run "${ROOT}/nrt_forcing_setup.sh" --site levante
    [ "${status}" -eq 1 ]
}

@test "unknown site: 3" {
    run "${ROOT}/nrt_forcing_setup.sh" --site nowhere --account acct
    [ "${status}" -eq 3 ]
}

@test "writes the config once and leaves an edited one alone" {
    run "${ROOT}/nrt_forcing_setup.sh" --site levante --account acct
    [ "${status}" -eq 0 ]
    grep -qx 'NRT_SITE=levante' "${ROOT}/nrt_forcing.conf"
    grep -qx 'NRT_SLURM_ACCOUNT=acct' "${ROOT}/nrt_forcing.conf"
    echo NRT_DEST_HOST=edited >>"${ROOT}/nrt_forcing.conf"
    run "${ROOT}/nrt_forcing_setup.sh" --site levante --account other
    [ "${status}" -eq 0 ]
    grep -qx 'NRT_DEST_HOST=edited' "${ROOT}/nrt_forcing.conf"
    grep -qx 'NRT_SLURM_ACCOUNT=acct' "${ROOT}/nrt_forcing.conf"
}

@test "an env that cannot run snakemake is moved aside and re-solved" {
    mkdir -p "${ROOT}/.pixi" && touch "${ROOT}/.pixi/broken"
    run "${ROOT}/nrt_forcing_setup.sh" --site levante --account acct
    [ "${status}" -eq 0 ]
    [ -e "$(echo "${ROOT}"/.pixi.broken-*/broken)" ]
    [ ! -e "${ROOT}/.pixi/broken" ]
}

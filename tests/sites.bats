# Every sites/<name>.conf defines the contract, and names things that exist.

@test "each site file is complete and self-consistent" {
    local repo=${BATS_TEST_DIRNAME}/..
    for conf in "${repo}"/sites/*.conf; do
        for var in NRT_PIXI_BIN NRT_SLURM_PARTITION NRT_SNAKEMAKE_PROFILE NRT_PRODUCER_CONFIG; do
            grep -q "^${var}=" "${conf}" || {
                echo "${conf} does not set ${var}"
                return 1
            }
        done
        (
            ROOT=${repo}
            # shellcheck source=/dev/null
            . "${conf}"
            [ -d "${repo}/producer/${NRT_SNAKEMAKE_PROFILE}" ] || {
                echo "${conf}: no producer/${NRT_SNAKEMAKE_PROFILE}"
                exit 1
            }
            [ -f "${repo}/producer/${NRT_PRODUCER_CONFIG}" ] || {
                echo "${conf}: no producer/${NRT_PRODUCER_CONFIG}"
                exit 1
            }
        ) || return 1
    done
}

@test "a cds site names its frequency, so no 6-hour file is called 1H" {
    local repo=${BATS_TEST_DIRNAME}/..
    for producer in "${repo}"/producer/config/*.yaml; do
        grep -q '^era5_source: *cds' "${producer}" || continue
        grep -q '^era5_freq: *6H' "${producer}" || {
            echo "${producer} is a cds source without era5_freq: 6H"
            return 1
        }
    done
}

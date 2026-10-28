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

@test "a cds site plans one CDS download per day, any other site none" {
    command -v snakemake >/dev/null || skip "no snakemake"
    local repo=${BATS_TEST_DIRNAME}/.. tmp=${BATS_TEST_TMPDIR}
    # A pool holding both days, so only a cds site has anything to fetch.
    for p in 138 155; do
        mkdir -p "${tmp}/pool/E5/ml/an/1H/${p}"
        touch "${tmp}/pool/E5/ml/an/1H/${p}/E5ml00_1H_2017-01-0"{1,2}"_${p}.grb"
    done
    for producer in "${repo}"/producer/config/*.yaml; do
        want=0
        grep -q '^era5_source: *cds' "${producer}" && want=2
        plan=$(snakemake --dry-run --snakefile "${repo}/producer/workflow/Snakefile" \
            --directory "${tmp}/work" --configfile "${producer}" \
            --config inproot="${tmp}/inproot" dir_era5="${tmp}/pool" \
            --resources cds=1 --jobs 10 \
            "${tmp}/inproot/storyline_forcing/tco79l137/rlxmlsh2017010"{1,2}{00,06,12,18}00 2>&1) || {
            echo "${producer}: ${plan}"
            return 1
        }
        got=$(awk '$1 == "download_era5_from_cds" { print $2; exit }' <<<"${plan}")
        [ "${got:-0}" -eq "${want}" ] || {
            echo "${producer}: ${got:-0} downloads for 2 days, expected ${want}"
            return 1
        }
    done
}

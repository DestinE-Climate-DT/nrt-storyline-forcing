import datetime
from pathlib import Path
import os

HOURS = ["00", "06", "12", "18"]

localrules: download_era5_from_cds


# ---------------------------------------------------------------------------
# ERA5 download from CDS (only active when era5_source: cds is set)
# ---------------------------------------------------------------------------
# On Levante, dir_era5 points at the local pool and files exist as source
# files. Elsewhere, set `era5_source: cds` and `dir_era5` to a local cache
# directory. The download rule then fetches per-day grib files from CDS
# matching the local pool structure. They are marked temp() so Snakemake
# deletes them once the nudging files have been produced.

if config.get('era5_source') == 'cds':
    rule download_era5_from_cds:
        output:
            temp(config.get("dir_era5") + "/E5/ml/an/1H/{param}/E5ml00_1H_{YYYY}-{MM}-{DD}_{param}.grb")
        wildcard_constraints:
            param=r"\d+",
            YYYY=r"\d{4}",
            MM=r"\d{2}",
            DD=r"\d{2}",
        run:
            import cdsapi

            out = str(output[0])
            os.makedirs(os.path.dirname(out), exist_ok=True)

            c = cdsapi.Client()
            c.retrieve("reanalysis-era5-complete", {
                "date": f"{wildcards.YYYY}-{wildcards.MM}-{wildcards.DD}",
                "time": "00/to/23",
                "stream": "oper",
                "type": "an",
                "levtype": "ml",
                "levelist": "1/to/137",
                "param": wildcards.param,
                "format": "grib",
            }, out)


# ---------------------------------------------------------------------------
# Nudging file creation from ERA5 grib files
# ---------------------------------------------------------------------------
# On Levante's /pool, recent dates (last ~2 months) exist only under the
# preliminary ERA5T tree (`ET/`), and older dates exist under the final ERA5
# tree (`E5/`). The CDS download rule always writes to the E5 path, so when
# `era5_source: cds` we keep that path. Otherwise we pick whichever file
# actually exists on disk at planning time.

def _era5_input(param):
    def _resolve(wildcards):
        base = config["dir_era5"]
        date = f"{wildcards.YYYY}-{wildcards.MM}-{wildcards.DD}"
        e5 = f"{base}/E5/ml/an/1H/{param}/E5ml00_1H_{date}_{param}.grb"
        if config.get("era5_source") == "cds":
            return e5
        et = f"{base}/ET/ml/an/1H/{param}/ETml00_1H_{date}_{param}.grb"
        return e5 if os.path.exists(e5) else et
    return _resolve


NUDGING_FILE_PATTERN = (
    config["inproot"] + "/storyline_forcing/tco{resolution}l137/rlxmlsh{YYYY}{MM}{DD}{HH}00"
)


rule create_nudging_file:
    input:
        file_138 = _era5_input("138"),
        file_155 = _era5_input("155"),
    output:
        expand(NUDGING_FILE_PATTERN, HH=HOURS, allow_missing=True),
    wildcard_constraints:
        YYYY=r"\d{4}",
        MM=r"\d{2}",
        DD=r"\d{2}",
    resources:
        cpus_per_task = 8,
        mem_mb = 16000,
        runtime = 30,
    params:
        cdo = config.get("cdo", "cdo"),
        outdir = lambda wildcards: config["inproot"] + f"/storyline_forcing/tco{wildcards.resolution}l137",
    shell:
        """
        YEAR={wildcards.YYYY}
        MONTH={wildcards.MM}
        DAY={wildcards.DD}

        FILE138={input.file_138}
        FILE155={input.file_155}

        TMPSPECTRAL="${{TMPDIR}}/tmp_spectral_${{YEAR}}${{MONTH}}${{DAY}}.grb"
        TMPCHPARAM="${{TMPDIR}}/tmp_chparam_${{YEAR}}${{MONTH}}${{DAY}}.grb"

        # Stage 1: merge 138+155, keep nudging hours, spectral-truncate.
        # `--eccodes` is needed by sp2sp for high-res input; no -f grb1
        # here so the intermediate inherits the input format.
        {params.cdo} --eccodes -P {resources.cpus_per_task} \
            -sp2sp,{wildcards.resolution} -selvar,vo,d \
            -selhour,0,6,12,18 \
            -merge $FILE138 $FILE155 \
            $TMPSPECTRAL

        # Stage 2: rename params and write GRIB1 *without* `--eccodes`.
        # ml137 has NV=276 which exceeds the GRIB1 spec's 8-bit NV field;
        # CDO's built-in codec writes it permissively, ecCodes refuses.
        {params.cdo} -P {resources.cpus_per_task} -b 64 -f grb1 \
            -chparam,12.2.0,138.128 -chparam,13.2.0,155.128 \
            $TMPSPECTRAL $TMPCHPARAM

        # Stage 3: split into per-hour outputs. Final write goes through
        # `--eccodes` (matching the original pipeline's last step); the NV
        # value on disk was already set by stage 2, so ecCodes only has to
        # preserve it, not encode 276 from scratch.
        for HH in 00 06 12 18; do
            HHNUM=$((10#$HH))
            OUT="{params.outdir}/rlxmlsh${{YEAR}}${{MONTH}}${{DAY}}${{HH}}00"
            {params.cdo} --eccodes -P {resources.cpus_per_task} -a -b 64 -f grb1 \
                -selhour,$HHNUM $TMPCHPARAM $OUT
        done

        rm -fv $TMPSPECTRAL $TMPCHPARAM
        """


# ---------------------------------------------------------------------------
# Convenience targets: request nudging files by day or month
# ---------------------------------------------------------------------------

localrules: nudging_day, nudging_month

rule nudging_day:
    input:
        lambda wildcards: expand(
            config["inproot"] + "/storyline_forcing/tco{resolution}l137/rlxmlsh{YYYY}{MM}{DD}{HH}00",
            resolution=wildcards.resolution,
            YYYY=wildcards.date[:4],
            MM=wildcards.date[4:6],
            DD=wildcards.date[6:8],
            HH=HOURS,
        ),
    output:
        "results/nudging/tco{resolution}/day_{date}",
    wildcard_constraints:
        date=r"\d{8}",
    shell:
        """
mkdir -p $(dirname {output})
touch {output}
"""


def _nudging_month_days(wildcards):
    import calendar
    year = int(wildcards.month[:4])
    month = int(wildcards.month[4:6])
    n_days = calendar.monthrange(year, month)[1]
    return [
        f"results/nudging/tco{wildcards.resolution}/day_{year}{month:02d}{d:02d}"
        for d in range(1, n_days + 1)
    ]


rule nudging_month:
    input:
        _nudging_month_days,
    output:
        "results/nudging/tco{resolution}/month_{month}",
    wildcard_constraints:
        month=r"\d{6}",
    shell:
        """
mkdir -p $(dirname {output})
touch {output}
"""

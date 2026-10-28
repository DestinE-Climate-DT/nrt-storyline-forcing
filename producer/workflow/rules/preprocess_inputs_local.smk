import datetime
from pathlib import Path
import os

from snakemake.exceptions import WorkflowError

HOURS = ["00", "06", "12", "18"]

# The pool's frequency level. Levante reads its 1H pool; a CDS cache holds only
# HOURS, so it is named 6H and never 1H.
FREQ = config.get("era5_freq", "1H")


def _flag(name):
    # --config passes strings, a configfile passes booleans.
    return str(config.get(name, "")).strip().lower() in ("1", "true", "yes")


def _era5_path(tree, param, date):
    base = config["dir_era5"]
    return f"{base}/{tree}/ml/an/{FREQ}/{param}/{tree}ml00_{FREQ}_{date}_{param}.grb"


localrules: download_era5_from_cds

# A site where the chain costs less than the queue it would wait in.
if _flag("local_compute"):
    localrules: create_nudging_file

# ---------------------------------------------------------------------------
# ERA5 download from CDS (only active when era5_source: cds is set)
# ---------------------------------------------------------------------------
# On Levante, dir_era5 points at the local pool and files exist as source
# files. Elsewhere, set `era5_source: cds` and `dir_era5` to a local cache
# directory. The download rule then fetches each day from CDS and splits it
# into per-param grib files matching the local pool structure. They are
# temp() unless era5_keep is set.

if config.get('era5_source') == 'cds':
    if FREQ == "1H":
        raise WorkflowError(
            "era5_source: cds fetches only " + "/".join(HOURS)
            + " -- set era5_freq to 6H so the path is not named 1H"
        )

    _ERA5_PARAMS = ("138", "155")
    # Each param's share of a day: 137 levels at each of HOURS.
    _ERA5_FIELDS = 137 * len(HOURS)

    def _era5_cache(param):
        out = _era5_path("E5", param, "{YYYY}-{MM}-{DD}")
        return out if _flag("era5_keep") else temp(out)

    # One request per day for both params, so MARS reads the day once; the
    # driver's --resources cds=1 keeps these jobs to one at a time.
    rule download_era5_from_cds:
        output:
            [_era5_cache(p) for p in _ERA5_PARAMS]
        wildcard_constraints:
            YYYY=r"\d{4}",
            MM=r"\d{2}",
            DD=r"\d{2}",
        resources:
            cds = 1,
        run:
            import subprocess
            import cdsapi

            date = f"{wildcards.YYYY}-{wildcards.MM}-{wildcards.DD}"
            for out in output:
                os.makedirs(os.path.dirname(out), exist_ok=True)

            # Split beside each target and rename, so a shared cache never
            # offers a half-written file to another user's Snakemake.
            both = output[0] + ".cds.part"
            parts = [out + ".part" for out in output]
            try:
                cdsapi.Client().retrieve("reanalysis-era5-complete", {
                    "date": date,
                    "time": "/".join(f"{h}:00:00" for h in HOURS),
                    "stream": "oper",
                    "type": "an",
                    "levtype": "ml",
                    "levelist": "1/to/137",
                    "param": "/".join(_ERA5_PARAMS),
                    "format": "grib",
                }, both)
                for param, part, out in zip(_ERA5_PARAMS, parts, output):
                    # grib_copy writes no file, and exits 0, when nothing matches.
                    subprocess.run(["grib_copy", "-w", f"paramId={param}", both, part], check=True)
                    if not os.path.exists(part) or os.path.getsize(part) == 0:
                        raise WorkflowError(f"CDS returned no param {param} for {date}")
                    n = int(subprocess.run(["grib_count", part], check=True,
                                           capture_output=True, text=True).stdout)
                    if n != _ERA5_FIELDS:
                        raise WorkflowError(
                            f"CDS returned {n} fields of param {param} for {date}, not {_ERA5_FIELDS}"
                        )
                    os.replace(part, out)
            finally:
                for f in [both, *parts]:
                    if os.path.exists(f):
                        os.remove(f)


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
        date = f"{wildcards.YYYY}-{wildcards.MM}-{wildcards.DD}"
        e5 = _era5_path("E5", param, date)
        if config.get("era5_source") == "cds":
            return e5
        return e5 if os.path.exists(e5) else _era5_path("ET", param, date)
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

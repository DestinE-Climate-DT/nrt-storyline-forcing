# nrt-storyline-forcing

Near-real-time ERA5 nudging forcing for IFS-FESOM storyline runs: produce, verify, ship.

A Snakemake rule turns ERA5 model-level vorticity and divergence into the four daily
`rlxmlsh<YYYYMMDDHH>00` GRIB1 records IFS reads for spectral nudging. `nrt_forcing.sh` wraps it
with one stable command: it produces the requested days, verifies each one, copies the verified
days to the directory a running experiment reads, and checks them again on arrival.

## Status

`v0.1.0-alpha.1`, the first tagged release. The interface may still change before `v0.1.0`.

Planned before `v0.1.0`:

- Verification of the field values, not only each day's record set and each record's `dataTime`.
- Rotation for the per-run logs and `events.jsonl`, which grow without bound.

`pixi.lock` stays untracked by design: every clone solves its own environment, and `pixi.toml`
pins the CDO and ecCodes builds the output bytes depend on. Whichever solve a clone gets, a site
is accepted only once a known day is proven byte-identical to a reference.

## Quick start

```bash
git clone https://github.com/DestinE-Climate-DT/nrt-storyline-forcing.git
cd nrt-storyline-forcing
./nrt_forcing_setup.sh --site <site> --account <slurm-account>

# One day, produced and kept here:
./nrt_forcing.sh --no-sync --dest-dir /any/path/tco79l137 20170101 20170101
```

Setup creates `inproot/` and `logs/`, solves the pixi environment (Snakemake, CDO 2.0.3,
ecCodes), writes `nrt_forcing.conf` from `nrt_forcing.conf.example` and then runs
`nrt_forcing_check.sh`. It is safe to re-run and never overwrites an existing `nrt_forcing.conf`.

`nrt_forcing_check.sh` also stands alone. It answers "can this machine run the producer" before a
real day depends on the answer: the pixi environment actually runs, the tools the driver shells
out to exist, the clone is not somewhere with a file quota a pixi environment will exhaust, the
SLURM **association** exists (a POSIX group is not one), the ERA5 source answers, `NRT_TMPDIR` is
writable, and the destination host accepts a `BatchMode` connection.

## Interface

```text
nrt_forcing.sh --dest-dir DIR [--dest-host HOST] [--plan] [--no-sync] [--expid ID] [--config FILE] <FIRST_DAY> <LAST_DAY>
```

- `DIR` is the directory the experiment reads; its last component (`tco<N>l137`) sets the grid.
  It is on `--dest-host`, else `NRT_DEST_HOST`, else this machine.
- `--dest-host` is an alias in **this** machine's ssh config, not the reader's. An absolute `DIR`
  whose root is missing here and no dest host is refused up front, rather than becoming a local
  directory nothing is ever shipped to.
- `--plan` asks Snakemake what is missing, and the destination which built days it lacks, and
  changes nothing.
- `--expid` labels logs and metrics only.

| Exit | Meaning |
| --- | --- |
| 0 | produced, and shipped unless `--no-sync`; with `--plan`, days to produce or to ship |
| 1 | bad arguments: a `DIR` not ending in `tco<N>l137`, or a remote `DIR` with no dest host |
| 3 | config, site file or producer missing |
| 4 | Snakemake refused the request or failed |
| 5 | a day failed verification |
| 6 | a verified day did not reach the destination intact |
| 10 | `--plan` found every day produced and at the destination, or a run is already in progress |

Without `--plan`, days that already exist are verified and shipped again, which repairs a damaged
destination.

A day passes verification when its four records exist with one non-zero size and each record's
`dataTime` is its own hour. Days are verified and shipped one at a time, so a gap does not hold
back the days around it.

Records land as `644`, whatever mode the producer's own umask or ACL gave them: readable by the
account that runs the experiment and by anyone else on that machine, writable only by the owner.

## Sites

| Site | ERA5 | Scheduler | Notes |
| --- | --- | --- | --- |
| `levante` | the local pool, `/pool/data/ERA5` (`1H`) | `compute` | final `E5/` and preliminary `ET/` trees, picked per day by what exists |
| `lumi` | CDS (`era5_source: cds`, `6H`) | `small` | needs `~/.cdsapirc`; downloads only the four nudging hours and keeps them, in the clone unless `NRT_ERA5_DIR` says otherwise |

A new machine needs three things: a `sites/<name>.conf`, a `producer/config/config-<name>.yaml`
naming its ERA5 source, and a proof that a known day is byte-identical to a reference. Then
`nrt_forcing_check.sh` has to pass on it.

### The CDS route

Where ERA5 is not on the machine, set `era5_source: cds`. The cache defaults to `era5-cache/`
inside the clone; set `NRT_ERA5_DIR` in `nrt_forcing.conf` to put it somewhere shared, the same
way `NRT_SLURM_ACCOUNT` is a per-clone setting rather than a tracked one. You need a CDS Personal
Access Token in `~/.cdsapirc`:

```
url: https://cds.climate.copernicus.eu/api
key: <token>
```

and the licence accepted **on the `reanalysis-era5-complete` dataset page**, which is a separate
acceptance from the general CDS terms. Without it every request returns `403 required licences not
accepted`, which is indistinguishable by status code from a bad token.

Only the four nudging hours are fetched, so a day costs ~902 MB rather than ~5.41 GB. Because
those files are not the hourly pool product, they are written at the **`6H`** level of the same
layout (`<dir_era5>/E5/ml/an/6H/<param>/E5ml00_6H_<date>_<param>.grb`) and a `cds` source
configured with `era5_freq: 1H` is refused rather than allowed to mislabel them.

## Configuration

| File | Holds |
| --- | --- |
| `nrt_forcing.conf` | per clone: `NRT_SITE`, `NRT_SLURM_ACCOUNT`, `NRT_DEST_HOST`, optional `NRT_TMPDIR` and `NRT_ERA5_*` |
| `sites/<name>.conf` | per machine: pixi location, SLURM partition, Snakemake profile, producer config, tmpdir |
| `producer/config/config-<site>.yaml` | where ERA5 is on that machine: `dir_era5`, `era5_source`, `era5_freq`, `era5_keep` |

Optional environment overrides: `NRT_SNAKEMAKE_JOBS` (default 10), `NRT_CDO` (a CDO binary other
than the environment's), and `NRT_ERA5_DIR` / `NRT_ERA5_SOURCE` / `NRT_ERA5_FREQ` /
`NRT_ERA5_KEEP`, which override the site's producer config without editing a tracked file.

## Layout

```text
producer/              the Snakemake rule and its configs
sites/                 one file per machine
inproot/storyline_forcing/<grid>/rlxmlsh<YYYYMMDDHH>00    produced records (untracked)
logs/<grid>/           run logs, events.jsonl, nrt_forcing.prom (untracked)
tmp/                   CDO intermediates, when the site points NRT_TMPDIR here (untracked)
era5-cache/            downloaded ERA5, for a cds site with no NRT_ERA5_DIR (untracked)
.pixi-home/            the pixi CLI, where a site puts it in the clone (untracked)
```

## Observability

Each grid gets its own log directory:

- `<first>_<last>_<runid>.log`: the whole run, for a human. An idle `--plan` leaves none.
- `events.jsonl`: one flat JSON object per event (`start`, `nothing_to_do`, `unshipped`,
  `dest_unreachable`, `already_running`,
  `plan_refused`, `produced`, `produce_failed`, `verified`, `verify_failed`, `shipped`,
  `ship_failed`, `landed`, `land_failed`, `end`), each carrying `run_id`, `expid`, `grid`, days,
  user and host.
- `nrt_forcing.prom`: Prometheus textfile gauges. Alert on
  `nrt_forcing_last_success_timestamp_seconds` and `nrt_forcing_last_shipped_day`, which runs
  that ship nothing carry forward.

## Tests

```bash
shellcheck -S error nrt_forcing.sh nrt_forcing_setup.sh nrt_forcing_check.sh sites/*.conf tests/mocks/*
shfmt -i 4 -d nrt_forcing.sh nrt_forcing_setup.sh nrt_forcing_check.sh tests/mocks
bats tests
```

The tests replace `pixi`, `snakemake`, `grib_get`, `ssh` and `rsync` with mocks, and need GNU
`stat` and `date` (Linux, or a Linux container).

## Credits

The forcing rule (`producer/workflow/rules/preprocess_inputs_local.smk`) is by Sebastian Beyer,
building on an initial version by Paul Gierz. The driver is by Muhammad Shafeeque. Authors, in
citation order: Sebastian Beyer, Muhammad Shafeeque, Paul Gierz, Miguel Andrés-Martínez (see
`CITATION.cff`).

## License

Apache License 2.0, see `LICENSE` and `NOTICE`.

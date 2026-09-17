# nrt-storyline-forcing

Near-real-time ERA5 nudging forcing for IFS-FESOM storyline runs: produce, verify, ship.

A Snakemake rule turns ERA5 model-level vorticity and divergence into the four daily
`rlxmlsh<YYYYMMDDHH>00` GRIB1 records IFS reads for spectral nudging. `nrt_forcing.sh` wraps it
with one stable command: it produces the requested days, verifies each one, copies the verified
days to the directory a running experiment reads, and checks them again on arrival.

## Quick start

```bash
git clone https://github.com/DestinE-Climate-DT/nrt-storyline-forcing.git
cd nrt-storyline-forcing
./nrt_forcing_setup.sh --site levante --account <slurm-account>

# One day, produced and kept here:
./nrt_forcing.sh --no-sync --dest-dir /any/path/tco79l137 20170101 20170101
```

Setup creates `inproot/` and `logs/`, solves the pixi environment (Snakemake, CDO 2.0.3,
ecCodes) and writes `nrt_forcing.conf` from `nrt_forcing.conf.example`. It is safe to re-run and
never overwrites an existing `nrt_forcing.conf`.

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

## Configuration

| File | Holds |
| --- | --- |
| `nrt_forcing.conf` | per clone: `NRT_SITE`, `NRT_SLURM_ACCOUNT`, `NRT_DEST_HOST`, optional `NRT_TMPDIR` |
| `sites/<name>.conf` | per machine: pixi location, SLURM partition, Snakemake profile, producer config |
| `producer/config/config-<site>.yaml` | where ERA5 is on that machine |

Optional environment overrides: `NRT_SNAKEMAKE_JOBS` (default 10) and `NRT_CDO` (a CDO binary
other than the environment's).

A new machine needs a `sites/<name>.conf`, a producer config naming its ERA5 directory (or
`era5_source: cds` with a CDS key), and a proof that a known day is byte-identical to a reference.

## Layout

```text
producer/              the Snakemake rule and its configs
sites/                 one file per machine
inproot/storyline_forcing/<grid>/rlxmlsh<YYYYMMDDHH>00    produced records (untracked)
logs/<grid>/           run logs, events.jsonl, nrt_forcing.prom (untracked)
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
shellcheck -S error nrt_forcing.sh nrt_forcing_setup.sh sites/*.conf tests/mocks/*
shfmt -i 4 -d nrt_forcing.sh nrt_forcing_setup.sh tests/mocks
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

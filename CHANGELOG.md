# Changelog

Versions follow [Semantic Versioning](https://semver.org/). While the major version is `0`,
the command-line interface and the exit codes may change between releases.

## v0.1.0-alpha.1 - 2026-09-17

First tagged release: the near-real-time storyline forcing pipeline as a repository that can be
cloned on any machine and pointed at a running experiment.

### Added

- `nrt_forcing.sh`: produce, verify and ship a day range in one command, with the exit codes a
  cron tick classifies (0, 1, 3, 4, 5, 6, 10) and `--plan` for a view that changes nothing.
- Destination handling: `--dest-dir` is the directory the experiment reads and its last component
  (`tco<N>l137`) sets the grid; `--dest-host` is an ssh alias of the producing machine. A remote
  directory given with no dest host, or a directory not matching the grid form, is refused before
  anything is produced.
- Per-day verification of the four `rlxmlsh<YYYYMMDDHH>00` records: all present, one non-zero
  size, and each record's `dataTime` its own hour. Days are verified and shipped one at a time,
  so a gap does not hold back the days around it.
- Verification again on arrival, so a day counts as delivered only once it landed intact, and
  re-running over existing days repairs a damaged destination.
- `nrt_forcing_setup.sh`: creates `inproot/` and `logs/`, solves the pixi environment and writes
  `nrt_forcing.conf` from the example. Safe to re-run; never overwrites an existing config.
- Observability: one log per run that did work, `events.jsonl` for log shipping, and Prometheus
  textfile gauges whose freshness is carried forward by runs that ship nothing.
- The forcing rule vendored under `producer/` with attribution (see `NOTICE` and `CITATION.cff`),
  a pinned environment (CDO 2.0.3, ecCodes 2.26.0, Snakemake 9.26) and a Levante site file.
- CI on every push: shellcheck, shfmt, and bats against mocked `pixi`, `snakemake`, `grib_get`,
  `ssh` and `rsync`, plus a gitleaks scan of the full history.

### Not yet in this release

Further sites and the CDS route, verification of field values rather than record shape and
`dataTime`, and rotation of the per-run logs and `events.jsonl` are all planned before `v0.1.0`.
`pixi.lock` stays untracked by design; see the Status section of `README.md`.

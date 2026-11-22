# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-11-22

### Fixed

- Claims, renewals, and `prune/1` run through the repository's dynamic repo
  (`get_dynamic_repo/0`), so a repository started without a registered name
  and selected with `put_dynamic_repo/1` works. Before, every call failed with
  "could not lookup Ecto repo … because it was not started or it does not
  exist".

## [0.1.0] - 2026-11-22

### Added

- `PeriodicalEcto`, a `Periodical.Coordinator` for PostgreSQL (one
  `INSERT … ON CONFLICT … WHERE` per claim) and MariaDB/MySQL (delete expired,
  then `INSERT IGNORE`), with leases on the database clock, owner-checked
  renewal, and `prune/1` for expired rows.
- `PeriodicalEcto.Migration` creates and drops the claims table, with optional
  `:table` and `:prefix`.

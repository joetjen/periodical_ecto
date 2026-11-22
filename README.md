# PeriodicalEcto

A [Periodical](https://hex.pm/packages/periodical) coordinator that keeps
claims in a database table through Ecto, so a schedule registered on several
instances runs each occurrence on only one of them. Works with PostgreSQL and
MariaDB/MySQL.

Each instance claims the run on the schedule's row; the instance that takes the
row runs the callback, and the others skip the occurrence. Leases are computed
and compared by the database's clock.

## Installation

```elixir
def deps do
  [
    {:periodical, "~> 0.2"},
    {:periodical_ecto, "~> 0.1"},
    {:postgrex, "~> 0.20"}   # or {:myxql, "~> 0.8"}
  ]
end
```

## Usage

Create the table:

```elixir
defmodule MyApp.Repo.Migrations.AddPeriodicalClaims do
  use Ecto.Migration

  def up, do: PeriodicalEcto.Migration.up()
  def down, do: PeriodicalEcto.Migration.down()
end
```

Configure the coordinator (the repository must start before Periodical fires):

```elixir
config :periodical, Periodical.Config,
  coordinator: {PeriodicalEcto, repo: MyApp.Repo}
```

and name the schedules that should run once across the cluster:

```elixir
Periodical.every("FREQ=DAILY;BYHOUR=3;BYMINUTE=0;BYSECOND=0", MyApp.Billing, :close_day, [],
  name: :close_day
)
```

| Option | Default | Purpose |
| --- | --- | --- |
| `:repo` | required | Ecto repository (Postgres or MyXQL adapter) |
| `:table` | `"periodical_claims"` | Claims table |
| `:prefix` | repository default | Schema (PostgreSQL) or database (MariaDB/MySQL) |

The migration takes the same `:table` and `:prefix`.

The table holds at most one row per coordinated schedule; a row is reused when
its schedule is next claimed. `PeriodicalEcto.prune/1` deletes expired rows
left by schedules that no longer exist, and can run as a Periodical schedule
itself.

Lease length, strategies, failure handling and which schedules are coordinated
are Periodical's: see `Periodical.Coordinator`.

## Development

The suite runs against a real PostgreSQL and MariaDB:

```sh
docker compose up -d
mix test
```

`PERIODICAL_ECTO_POSTGRES_URL` and `PERIODICAL_ECTO_MYSQL_URL` point it
elsewhere. Until the Periodical release with `Periodical.Coordinator` is on
Hex, add `PERIODICAL_PATH=../periodical` to build against a checkout.

## License

Apache License 2.0; see [LICENSE](LICENSE).

defmodule PeriodicalEcto.Migration do
  @moduledoc """
  Creates and drops the claims table. Call it from one of your migrations:

      defmodule MyApp.Repo.Migrations.AddPeriodicalClaims do
        use Ecto.Migration

        def up, do: PeriodicalEcto.Migration.up()
        def down, do: PeriodicalEcto.Migration.down()
      end

  Both take `:table` and `:prefix`, matching the coordinator's options when
  those are not the defaults:

      def up, do: PeriodicalEcto.Migration.up(table: "scheduler_claims", prefix: "ops")

  The table:

  | Column | Type | Purpose |
  | --- | --- | --- |
  | `key` | `varchar(64)`, primary key | `Periodical.Coordinator.key/1` of the schedule name |
  | `name` | `varchar(255)` | The schedule name, for people reading the table |
  | `token` | `varchar(64)` | The claim holding the lease |
  | `scheduled_at` | UTC timestamp, microseconds | The occurrence the holder claimed |
  | `expires_at` | UTC timestamp, microseconds, indexed | When the lease ends, by the database clock |
  """

  use Ecto.Migration

  @doc "Creates the claims table and its expiry index."
  @spec up(keyword()) :: :ok
  def up(options \\ []) do
    {table, prefix} = names(options)

    create table(table, primary_key: false, prefix: prefix) do
      add(:key, :string, size: 64, primary_key: true)
      add(:name, :string, size: 255, null: false)
      add(:token, :string, size: 64, null: false)
      add(:scheduled_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
    end

    create(index(table, [:expires_at], prefix: prefix))
    :ok
  end

  @doc "Drops the claims table."
  @spec down(keyword()) :: :ok
  def down(options \\ []) do
    {table, prefix} = names(options)
    drop(table(table, prefix: prefix))
    :ok
  end

  @spec names(keyword()) :: {String.t(), String.t() | nil}
  defp names(options) do
    table = Keyword.get(options, :table, PeriodicalEcto.default_table())
    prefix = Keyword.get(options, :prefix)

    unless PeriodicalEcto.identifier?(table) and (prefix == nil or PeriodicalEcto.identifier?(prefix)) do
      raise ArgumentError, "PeriodicalEcto table and prefix must be plain SQL identifiers"
    end

    {table, prefix}
  end
end

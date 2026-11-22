defmodule PeriodicalEcto do
  @moduledoc """
  A `Periodical.Coordinator` that keeps claims in a database table through Ecto.

  Every instance that shares a named Periodical schedule claims each run in
  one table, keyed on the schedule; the instance whose claim takes the row runs
  the callback. Leases are computed and compared by the database's clock, so
  the instances' own clock skew does not affect them.

  Supported repositories: `Ecto.Adapters.Postgres` (PostgreSQL) and
  `Ecto.Adapters.MyXQL` (MariaDB, MySQL).

  ## Setup

  Create the table with a migration:

      defmodule MyApp.Repo.Migrations.AddPeriodicalClaims do
        use Ecto.Migration

        def up, do: PeriodicalEcto.Migration.up()
        def down, do: PeriodicalEcto.Migration.down()
      end

  and configure the coordinator:

      config :periodical, Periodical.Config,
        coordinator: {PeriodicalEcto, repo: MyApp.Repo}

  Options (the same for the migration where they apply):

  - `:repo` (required) — the Ecto repository.
  - `:table` — the table name; `"periodical_claims"` by default.
  - `:prefix` — the schema (PostgreSQL) or database (MariaDB/MySQL) the table
    lives in; the repository's default when omitted.

  The repository must be started before Periodical fires its first
  coordinated occurrence. A database that is unreachable makes claims fail
  with an error, which Periodical's `:coordinator_error` policy handles.

  ## How a claim decides

  PostgreSQL decides in one statement: an `INSERT … ON CONFLICT (key) DO
  UPDATE … WHERE expires_at <= now` takes the row when it is free or its lease
  has expired, and touches nothing otherwise; one affected row means the claim
  won.

  MariaDB/MySQL has no conditional upsert that reports the outcome reliably,
  so a claim deletes the key's row if its lease has expired and then inserts
  with `INSERT IGNORE`. Of concurrent claims, only one insert can succeed on
  the primary key.

  ## Expired rows

  A row is replaced when its schedule is next claimed, so a table holds at
  most one row per coordinated schedule. Rows of schedules that no longer
  exist stay; `prune/1` deletes every expired row, and can itself be a
  Periodical schedule.
  """

  alias Periodical.Coordinator.Claim

  @behaviour Periodical.Coordinator

  @default_table "periodical_claims"
  @name_length 255
  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_]{0,62}\z/

  ##
  ## Callback Implementations
  ##

  @doc """
  Claims the schedule's row for `claim.ttl_ms`.

  Returns `:won` when this claim took the row, `:lost` when another claim's
  lease is still running, and `{:error, reason}` when the database failed.
  """
  @impl Periodical.Coordinator
  @spec claim(Claim.t(), keyword()) :: :won | :lost | {:error, term()}
  def claim(%Claim{} = claim, options) do
    with {:ok, repo, dialect, table} <- target(options) do
      claim_row(dialect, repo, table, claim)
    end
  end

  @doc """
  Extends the lease to `claim.ttl_ms` from now while the row still holds this claim's token.

  Returns `:lost` when the lease expired or the row belongs to another claim.
  """
  @impl Periodical.Coordinator
  @spec renew(Claim.t(), keyword()) :: :ok | :lost | {:error, term()}
  def renew(%Claim{} = claim, options) do
    with {:ok, repo, dialect, table} <- target(options) do
      {sql, params} = renew_sql(dialect, table, claim)

      case query(repo, sql, params) do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, %{num_rows: 0}} -> :lost
        {:error, error} -> {:error, error}
      end
    end
  end

  ##
  ## Public API
  ##

  @doc """
  Deletes every row whose lease has expired, returning how many.

  Takes the same options as the coordinator:

      PeriodicalEcto.prune(repo: MyApp.Repo)
      #=> {:ok, 3}
  """
  @spec prune(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(options) do
    with {:ok, repo, dialect, table} <- target(options),
         {:ok, %{num_rows: count}} <- query(repo, "DELETE FROM #{table} WHERE expires_at <= #{now(dialect)}", []) do
      {:ok, count}
    end
  end

  @doc false
  @spec default_table() :: String.t()
  def default_table, do: @default_table

  @doc false
  @spec identifier?(term()) :: boolean()
  def identifier?(value), do: is_binary(value) and Regex.match?(@identifier, value)

  ##
  ## Private Functions
  ##

  # Claiming

  @spec claim_row(:postgres | :mysql, module(), String.t(), Claim.t()) :: :won | :lost | {:error, term()}
  defp claim_row(:postgres, repo, table, claim) do
    sql = """
    INSERT INTO #{table} (key, name, token, scheduled_at, expires_at)
    VALUES ($1, $2, $3, $4, #{now(:postgres)} + ($5::bigint * interval '1 millisecond'))
    ON CONFLICT (key) DO UPDATE
      SET name = EXCLUDED.name, token = EXCLUDED.token,
          scheduled_at = EXCLUDED.scheduled_at, expires_at = EXCLUDED.expires_at
      WHERE #{table}.expires_at <= #{now(:postgres)}
    """

    case query(repo, sql, row_params(claim)) do
      {:ok, %{num_rows: 1}} -> :won
      {:ok, %{num_rows: 0}} -> :lost
      {:error, error} -> {:error, error}
    end
  end

  defp claim_row(:mysql, repo, table, claim) do
    delete = "DELETE FROM #{table} WHERE `key` = ? AND expires_at <= #{now(:mysql)}"

    insert = """
    INSERT IGNORE INTO #{table} (`key`, name, token, scheduled_at, expires_at)
    VALUES (?, ?, ?, ?, TIMESTAMPADD(MICROSECOND, ? * 1000, #{now(:mysql)}))
    """

    with {:ok, _deleted} <- query(repo, delete, [claim.key]),
         {:ok, %{num_rows: inserted}} <- query(repo, insert, row_params(claim)) do
      if inserted == 1, do: :won, else: :lost
    end
  end

  @spec renew_sql(:postgres | :mysql, String.t(), Claim.t()) :: {String.t(), list()}
  defp renew_sql(:postgres, table, claim) do
    {"""
     UPDATE #{table} SET expires_at = #{now(:postgres)} + ($3::bigint * interval '1 millisecond')
     WHERE key = $1 AND token = $2 AND expires_at > #{now(:postgres)}
     """, [claim.key, claim.token, claim.ttl_ms]}
  end

  defp renew_sql(:mysql, table, claim) do
    {"""
     UPDATE #{table} SET expires_at = TIMESTAMPADD(MICROSECOND, ? * 1000, #{now(:mysql)})
     WHERE `key` = ? AND token = ? AND expires_at > #{now(:mysql)}
     """, [claim.ttl_ms, claim.key, claim.token]}
  end

  # Column values in insert order; the ttl comes last.
  @spec row_params(Claim.t()) :: list()
  defp row_params(claim) do
    [claim.key, display_name(claim.name), claim.token, utc_naive(claim.scheduled_at), claim.ttl_ms]
  end

  # The database's current UTC time, independent of the session time zone.
  @spec now(:postgres | :mysql) :: String.t()
  defp now(:postgres), do: "(clock_timestamp() AT TIME ZONE 'UTC')"
  defp now(:mysql), do: "UTC_TIMESTAMP(6)"

  # A readable, bounded rendering of the schedule name for operators.
  @spec display_name(Periodical.schedule_name()) :: String.t()
  defp display_name(name), do: name |> inspect(limit: 16, printable_limit: 128) |> String.slice(0, @name_length)

  @spec utc_naive(DateTime.t()) :: NaiveDateTime.t()
  defp utc_naive(datetime),
    do: datetime |> DateTime.to_unix(:microsecond) |> DateTime.from_unix!(:microsecond) |> DateTime.to_naive()

  # Options

  # Resolves the repository, its SQL dialect, and the quoted table name.
  @spec target(keyword()) :: {:ok, module(), :postgres | :mysql, String.t()} | {:error, term()}
  defp target(options) do
    repo = Keyword.fetch!(options, :repo)
    table = Keyword.get(options, :table, @default_table)
    prefix = Keyword.get(options, :prefix)

    with {:ok, dialect} <- dialect(repo),
         :ok <- check_identifier(:table, table),
         :ok <- check_identifier(:prefix, prefix) do
      {:ok, repo, dialect, quote_table(dialect, prefix, table)}
    end
  end

  @spec dialect(module()) :: {:ok, :postgres | :mysql} | {:error, term()}
  defp dialect(repo) do
    case repo.__adapter__() do
      Ecto.Adapters.Postgres -> {:ok, :postgres}
      Ecto.Adapters.MyXQL -> {:ok, :mysql}
      other -> {:error, {:unsupported_adapter, other}}
    end
  end

  @spec check_identifier(atom(), term()) :: :ok | {:error, term()}
  defp check_identifier(:prefix, nil), do: :ok
  defp check_identifier(field, value), do: if(identifier?(value), do: :ok, else: {:error, {:invalid_identifier, field}})

  @spec quote_table(:postgres | :mysql, String.t() | nil, String.t()) :: String.t()
  defp quote_table(:postgres, nil, table), do: ~s("#{table}")
  defp quote_table(:postgres, prefix, table), do: ~s("#{prefix}"."#{table}")
  defp quote_table(:mysql, nil, table), do: "`#{table}`"
  defp quote_table(:mysql, prefix, table), do: "`#{prefix}`.`#{table}`"

  # Runs one statement, converting a raised database error into an error tuple.
  @spec query(module(), String.t(), list()) :: {:ok, map()} | {:error, term()}
  defp query(repo, sql, params) do
    Ecto.Adapters.SQL.query(repo, sql, params, log: false)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end

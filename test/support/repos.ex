defmodule PeriodicalEctoTest.PgRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :periodical_ecto, adapter: Ecto.Adapters.Postgres
end

defmodule PeriodicalEctoTest.MyRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :periodical_ecto, adapter: Ecto.Adapters.MyXQL
end

defmodule PeriodicalEctoTest.PgDynamicRepo do
  @moduledoc false
  # Only ever started without a registered name, selected with put_dynamic_repo/1.
  use Ecto.Repo, otp_app: :periodical_ecto, adapter: Ecto.Adapters.Postgres
end

defmodule PeriodicalEctoTest.MyDynamicRepo do
  @moduledoc false
  # Only ever started without a registered name, selected with put_dynamic_repo/1.
  use Ecto.Repo, otp_app: :periodical_ecto, adapter: Ecto.Adapters.MyXQL
end

defmodule PeriodicalEctoTest.ClaimsMigration do
  @moduledoc false
  use Ecto.Migration

  def up, do: PeriodicalEcto.Migration.up()
  def down, do: PeriodicalEcto.Migration.down()
end

defmodule PeriodicalEctoTest.Repos do
  @moduledoc false

  # The databases the suite runs against: this package's docker-compose.yml
  # services unless the environment names others.

  alias PeriodicalEctoTest.{MyDynamicRepo, MyRepo, PgDynamicRepo, PgRepo}

  @doc false
  @spec all() :: [{String.t(), module(), String.t()}]
  def all do
    [
      {"postgres", PgRepo,
       System.get_env(
         "PERIODICAL_ECTO_POSTGRES_URL",
         "ecto://periodical:periodical@localhost:5442/periodical_ecto_test"
       )},
      {"mariadb", MyRepo,
       System.get_env("PERIODICAL_ECTO_MYSQL_URL", "ecto://periodical:periodical@localhost:3316/periodical_ecto_test")}
    ]
  end

  @doc "Pairs each database with a repository that is only started without a name."
  @spec dynamic() :: [{String.t(), module(), String.t()}]
  def dynamic do
    dynamic_repos = %{"postgres" => PgDynamicRepo, "mariadb" => MyDynamicRepo}
    for {label, _repo, url} <- all(), do: {label, Map.fetch!(dynamic_repos, label), url}
  end

  @doc "Starts a repository, unlinked so it outlives the calling process."
  @spec start(module(), String.t()) :: :ok
  def start(repo, url) do
    parent = self()

    spawn(fn ->
      {:ok, _pid} = repo.start_link(url: url, pool_size: 10, log: false)
      send(parent, :repo_started)
      Process.sleep(:infinity)
    end)

    receive do
      :repo_started -> :ok
    after
      10_000 -> raise "#{inspect(repo)} did not start"
    end
  end

  @doc "Recreates the claims table from the package's migration."
  @spec migrate(module()) :: :ok
  def migrate(repo) do
    Ecto.Adapters.SQL.query!(repo, "DROP TABLE IF EXISTS periodical_claims", [])
    Ecto.Adapters.SQL.query!(repo, "DROP TABLE IF EXISTS schema_migrations", [])
    Ecto.Migrator.up(repo, 1, PeriodicalEctoTest.ClaimsMigration, log: false)
    :ok
  end
end

defmodule PeriodicalEctoTest.Callbacks do
  @moduledoc false

  @doc false
  @spec record(Periodical.Trigger.t(), pid(), term()) :: :ok
  def record(trigger, recipient, label) do
    send(recipient, {:ran, label, Node.self(), trigger.scheduled_at, System.os_time(:millisecond)})
    :ok
  end
end

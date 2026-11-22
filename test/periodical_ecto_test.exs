defmodule PeriodicalEctoTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Periodical.Coordinator
  alias Periodical.Coordinator.Claim
  alias PeriodicalEctoTest.{Callbacks, Repos}

  for {label, repo, _url} <- Repos.all() do
    describe "#{label}" do
      @repo repo

      setup do
        Ecto.Adapters.SQL.query!(@repo, "DELETE FROM periodical_claims", [])
        {:ok, options: [repo: @repo]}
      end

      test "the first claim wins and later ones lose while the lease lasts", %{options: options} do
        assert :won = PeriodicalEcto.claim(claim(:job, 10_000), options)
        assert :lost = PeriodicalEcto.claim(claim(:job, 10_000), options)
        assert :won = PeriodicalEcto.claim(claim(:other_job, 10_000), options)
      end

      test "an expired lease is taken over in place", %{options: options} do
        assert :won = PeriodicalEcto.claim(claim(:job, 100), options)
        Process.sleep(150)
        second = claim(:job, 10_000)
        assert :won = PeriodicalEcto.claim(second, options)

        assert %{rows: [[token, name]]} =
                 Ecto.Adapters.SQL.query!(@repo, "SELECT token, name FROM periodical_claims", [])

        assert token == second.token
        assert name == ":job"
      end

      property "of any number of concurrent claims exactly one wins", %{options: options} do
        check all(claimers <- integer(2..30), max_runs: 10) do
          name = {:concurrent, System.unique_integer([:positive])}

          results =
            1..claimers
            |> Task.async_stream(fn _ -> PeriodicalEcto.claim(claim(name, 10_000), options) end, max_concurrency: 10)
            |> Enum.map(fn {:ok, result} -> result end)

          assert Enum.count(results, &(&1 == :won)) == 1
          assert Enum.count(results, &(&1 == :lost)) == claimers - 1
        end
      end

      test "concurrent claims on an expired lease still produce one winner", %{options: options} do
        assert :won = PeriodicalEcto.claim(claim(:expiring, 50), options)
        Process.sleep(80)

        results =
          1..20
          |> Task.async_stream(fn _ -> PeriodicalEcto.claim(claim(:expiring, 10_000), options) end, max_concurrency: 10)
          |> Enum.map(fn {:ok, result} -> result end)

        assert Enum.count(results, &(&1 == :won)) == 1
      end

      test "renew extends only the holder's lease", %{options: options} do
        mine = claim(:job, 150)
        assert :won = PeriodicalEcto.claim(mine, options)
        assert :lost = PeriodicalEcto.renew(%{claim(:job, 1_000) | token: "someone-else"}, options)
        assert :ok = PeriodicalEcto.renew(%{mine | ttl_ms: 1_000}, options)
        Process.sleep(250)
        assert :lost = PeriodicalEcto.claim(claim(:job, 100), options)
      end

      test "renew reports an expired lease as lost", %{options: options} do
        mine = claim(:job, 50)
        assert :won = PeriodicalEcto.claim(mine, options)
        Process.sleep(80)
        assert :lost = PeriodicalEcto.renew(mine, options)
      end

      test "prune deletes only expired rows", %{options: options} do
        assert :won = PeriodicalEcto.claim(claim(:short, 50), options)
        assert :won = PeriodicalEcto.claim(claim(:long, 10_000), options)
        Process.sleep(80)
        assert {:ok, 1} = PeriodicalEcto.prune(options)
        assert :lost = PeriodicalEcto.claim(claim(:long, 100), options)
      end

      test "a missing table is an error, and bad identifiers are refused", %{options: options} do
        assert {:error, _reason} = PeriodicalEcto.claim(claim(:job, 100), Keyword.put(options, :table, "no_such_table"))

        assert {:error, {:invalid_identifier, :table}} =
                 PeriodicalEcto.claim(claim(:job, 100), Keyword.put(options, :table, "claims; DROP TABLE x"))
      end

      test "Periodical runs a named schedule only while it wins", %{options: options} do
        restart_periodical(coordinator: {PeriodicalEcto, options})
        on_exit(fn -> restart_periodical([]) end)

        at = soon()
        assert {:ok, _id} = Periodical.once(at, Callbacks, :record, [self(), :free], name: :free)
        assert_receive {:ran, :free, _, ^at, _}, 1_000

        assert :won = PeriodicalEcto.claim(claim(:held, 10_000), options)
        assert {:ok, _id} = Periodical.once(soon(), Callbacks, :record, [self(), :held], name: :held)
        refute_receive {:ran, :held, _, _, _}, 300
      end
    end
  end

  for {label, repo, url} <- Repos.dynamic() do
    describe "#{label}, repository without a registered name" do
      @repo repo
      @url url

      setup do
        pool = start_supervised!({@repo, name: nil, url: @url, pool_size: 2, log: false})
        {:ok, pool: pool}
      end

      test "claim, renew, and prune run through the dynamic repo", %{pool: pool} do
        options = [repo: @repo]
        @repo.put_dynamic_repo(pool)
        Ecto.Adapters.SQL.query!(pool, "DELETE FROM periodical_claims", [])

        mine = claim(:dynamic, 10_000)
        assert :won = PeriodicalEcto.claim(mine, options)
        assert :lost = PeriodicalEcto.claim(claim(:dynamic, 10_000), options)
        assert :ok = PeriodicalEcto.renew(%{mine | ttl_ms: 50}, options)
        Process.sleep(80)
        assert {:ok, 1} = PeriodicalEcto.prune(options)
        assert %{rows: [[0]]} = Ecto.Adapters.SQL.query!(pool, "SELECT COUNT(*) FROM periodical_claims", [])
      end

      test "without a dynamic repo the unnamed repository is an error, not a crash" do
        assert {:error, _reason} = PeriodicalEcto.claim(claim(:dynamic, 10_000), repo: @repo)
      end
    end
  end

  test "the migration honours a custom table name" do
    repo = PeriodicalEctoTest.PgRepo
    Ecto.Adapters.SQL.query!(repo, "DROP TABLE IF EXISTS custom_claims", [])

    defmodule CustomMigration do
      use Ecto.Migration
      def up, do: PeriodicalEcto.Migration.up(table: "custom_claims")
      def down, do: PeriodicalEcto.Migration.down(table: "custom_claims")
    end

    :ok = Ecto.Migrator.up(repo, 2, CustomMigration, log: false)
    assert :won = PeriodicalEcto.claim(claim(:job, 1_000), repo: repo, table: "custom_claims")
    :ok = Ecto.Migrator.down(repo, 2, CustomMigration, log: false)
    assert_raise ArgumentError, fn -> PeriodicalEcto.Migration.up(table: "bad name") end
  end

  defp claim(name, ttl_ms) do
    %Claim{
      key: Coordinator.key(name),
      name: name,
      scheduled_at: DateTime.utc_now(),
      token: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower),
      ttl_ms: ttl_ms
    }
  end

  defp soon, do: DateTime.add(DateTime.utc_now(), 40, :millisecond)

  defp restart_periodical(settings) do
    _ignored = Application.stop(:periodical)
    :ok = Application.put_env(:periodical, Periodical.Config, settings)
    {:ok, _applications} = Application.ensure_all_started(:periodical)
    :ok
  end
end

defmodule PeriodicalEcto.ClusterTest do
  # Three Periodical instances on their own peer nodes, coordinated through a
  # real PostgreSQL or MariaDB.
  use ExUnit.Case, async: false

  alias PeriodicalEctoTest.{Callbacks, Repos}

  @moduletag :cluster
  @moduletag timeout: 60_000

  setup_all do
    {_output, 0} = System.cmd("epmd", ["-daemon"])

    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"periodical_ecto_test_#{System.unique_integer([:positive])}@127.0.0.1", :longnames)
    end

    :ok
  end

  for {label, repo, url} <- Repos.all() do
    @repo repo
    @url url
    test "#{label}: one of three instances runs each occurrence" do
      Ecto.Adapters.SQL.query!(@repo, "DELETE FROM periodical_claims", [])
      for label <- [:a, :b, :c], do: start_instance(label, @repo, @url)

      runs = collect(3_500)

      assert length(runs) in 2..5
      gaps = runs |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b.ran_at - a.ran_at end)
      assert Enum.all?(gaps, &(&1 >= 800)), "runs closer than a lease: #{inspect(gaps)}"
    end
  end

  defp start_instance(label, repo, url) do
    {:ok, _peer, node} =
      :peer.start_link(%{name: :peer.random_name(~c"periodical_ecto"), host: ~c"127.0.0.1", longnames: true})

    :ok = :erpc.call(node, :code, :add_pathsa, [:code.get_path()])
    {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:ecto_sql])
    {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:postgrex])
    {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:myxql])
    :ok = :erpc.call(node, Repos, :start, [repo, url])

    :ok =
      :erpc.call(node, Application, :put_env, [
        :periodical,
        Periodical.Config,
        [coordinator: {PeriodicalEcto, repo: repo}]
      ])

    {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:periodical])

    {:ok, _id} =
      :erpc.call(node, Periodical, :every, ["FREQ=SECONDLY", Callbacks, :record, [self(), label], [name: :shared]])
  end

  defp collect(window_ms), do: collect_until(System.monotonic_time(:millisecond) + window_ms, [])

  defp collect_until(deadline, runs) do
    receive do
      {:ran, label, _node, _scheduled_at, ran_at} -> collect_until(deadline, [%{label: label, ran_at: ran_at} | runs])
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> Enum.sort_by(runs, & &1.ran_at)
    end
  end
end

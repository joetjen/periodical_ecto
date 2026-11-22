{:ok, _apps} = Application.ensure_all_started(:ecto_sql)
{:ok, _apps} = Application.ensure_all_started(:postgrex)
{:ok, _apps} = Application.ensure_all_started(:myxql)

for {_label, repo, url} <- PeriodicalEctoTest.Repos.all() do
  :ok = PeriodicalEctoTest.Repos.start(repo, url)
  :ok = PeriodicalEctoTest.Repos.migrate(repo)
end

ExUnit.start()

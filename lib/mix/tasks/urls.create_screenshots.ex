defmodule Mix.Tasks.Urls.CreateScreenshots do
  @moduledoc false

  use Mix.Task
  import Ecto.Query
  alias Vutuv.Accounts.User
  alias Vutuv.Repo

  @shortdoc "Creates screenshots for all Urls."

  def run(_args) do
    Mix.Task.run("app.start", [])
    users = Repo.all(from(u in User))

    for user <- users do
      user = Vutuv.Repo.preload(user, :urls)
      process_user_urls(user)
    end
  end

  defp process_user_urls(%{urls: []}), do: :ok

  defp process_user_urls(user) do
    IO.puts("#{user.first_name} #{user.last_name}")

    # A blocklisted page is skipped outright rather than walked past a Chromium
    # run that would refuse it anyway (Vutuv.ScreenshotBlocklist).
    for url <- user.urls,
        !url.screenshot,
        !url.broken?,
        !Vutuv.ScreenshotBlocklist.blocked?(url.value) do
      IO.puts("-> #{url.value}")
      Vutuv.PageScreenshot.generate_screenshot(url)
      :timer.sleep(500)
    end
  end
end

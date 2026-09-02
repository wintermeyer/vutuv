defmodule Mix.Tasks.Urls.CreateScreenshots do
  @moduledoc false

  use Mix.Task

  alias Vutuv.PageScreenshot

  @shortdoc "Captures every profile link still waiting for a screenshot."

  # The manual version of Vutuv.PageScreenshot.Sweeper: same batch, drained in
  # one go instead of one batch per five minutes. It walks `due/1` rather than
  # its own filter, so "which link still needs a picture" — and the retry clock
  # that keeps an unshootable page from being tried on every pass — is decided
  # in one place. The drain terminates because each pass stamps its batch,
  # which takes those links out of the next one.
  def run(_args) do
    Mix.Task.run("app.start", [])
    drain(0)
  end

  defp drain(done) do
    case PageScreenshot.capture_due() do
      0 -> Mix.shell().info("#{done} link(s) attempted")
      count -> drain(done + count)
    end
  end
end

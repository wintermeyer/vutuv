defmodule Mix.Tasks.Vutuv.Autoconsent.Vendor do
  @shortdoc "Copies @duckduckgo/autoconsent into priv/chrome/autoconsent"

  @moduledoc """
  Vendors the consent blocker the screenshot browser injects.

  `@duckduckgo/autoconsent` ships prebuilt, so this is a copy, not a build: the
  host-driven bundle and its CMP rule set land in `priv/chrome/autoconsent/`,
  where `Vutuv.PageScreenshot.Consent` reads them. Runs as the last step of
  `mix assets.setup`, right after `npm ci` has fetched the package.

  Copying (instead of committing the two files) keeps the rules current with an
  ordinary `npm update`; both copies are gitignored. A tree where this never
  ran simply has no consent blocker and captures dialogs as before, so the task
  reports a missing package and exits 0 rather than failing the build.
  """

  use Mix.Task

  @source "assets/node_modules/@duckduckgo/autoconsent/dist"
  @target "priv/chrome/autoconsent"

  # dist file -> the name we read it under. The playwright build is the
  # host-driven one (it talks to us over a binding, which is how we learn that
  # the opt-out finished); rules.json is the full CMP rule set it asks for.
  @files %{
    "autoconsent.playwright.js" => "autoconsent.js",
    "addon-mv3/rules.json" => "rules.json"
  }

  @impl Mix.Task
  def run(_args) do
    if File.dir?(@source) do
      File.mkdir_p!(@target)
      Enum.each(@files, &copy/1)
      Mix.shell().info("vendored autoconsent into #{@target}")
    else
      Mix.shell().info("skipping autoconsent: #{@source} is missing (run `npm ci` in assets/)")
    end
  end

  defp copy({from, to}) do
    File.cp!(Path.join(@source, from), Path.join(@target, to))
  end
end

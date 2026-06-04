defmodule VutuvWeb.TailwindWatcher do
  @moduledoc """
  Dev-only replacement for `tailwindcss --watch`.

  The Tailwind v4 standalone CLI's watch mode re-scans templates for class
  candidates but rebuilds from a *cached* copy of the entry CSS and its
  `@import`s, and ignores edits to those files entirely. Verified against
  v4.0.0 and v4.3.0 on macOS: a template save rebuilt with a stale
  `components.css`, and a CSS save triggered no rebuild at all. Since
  `components.css` is this project's design system, that silently ships wrong
  styles to the browser.

  So the dev watcher (see `config/dev.exs`) runs this instead: watch the CSS
  sources and the template tree with `file_system`, debounce event bursts, and
  run a fresh one-shot `tailwind` build each time (~70 ms). Every rebuild
  re-reads the whole import graph and re-scans sources, so both kinds of edits
  arrive correctly; `phoenix_live_reload` then refreshes the browser.
  """

  require Logger

  @debounce_ms 80
  @extensions ~w(.css .heex .ex .exs .js)

  @doc "Blocks forever (it is run as an endpoint watcher); rebuilds on changes."
  def watch(profile \\ :vutuv) do
    # `file_system` is a dev-only (transitive) dependency. Resolve the module
    # at runtime so this file still compiles in :test and :prod.
    fs = Module.concat([:FileSystem])

    dirs =
      Enum.map(
        ["assets/css", "assets/js", "lib/vutuv_web"],
        &Path.absname/1
      )

    {:ok, pid} = fs.start_link(dirs: dirs)
    fs.subscribe(pid)

    rebuild(profile)
    loop(profile)
  end

  defp loop(profile) do
    receive do
      {:file_event, _pid, {path, _events}} ->
        if Path.extname(path) in @extensions, do: debounce_and_rebuild(profile)
        loop(profile)

      {:file_event, _pid, :stop} ->
        :ok
    end
  end

  # Editors and compilers emit bursts of events; wait for a quiet gap, then
  # build once.
  defp debounce_and_rebuild(profile) do
    receive do
      {:file_event, _pid, {_path, _events}} -> debounce_and_rebuild(profile)
    after
      @debounce_ms -> rebuild(profile)
    end
  end

  defp rebuild(profile) do
    case Tailwind.install_and_run(profile, []) do
      0 -> :ok
      status -> Logger.warning("tailwind rebuild exited with status #{status}")
    end
  end
end

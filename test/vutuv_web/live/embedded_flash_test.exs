defmodule VutuvWeb.EmbeddedFlashTest do
  @moduledoc """
  A LiveView that declares no layout — bare `use Phoenix.LiveView`, the shape
  every `live_render`ed child here uses — renders its own tree and nothing else.
  The app's one `#toast-tray` sits in `app.html.heex`, around a page some
  controller rendered, so a `put_flash/3` in such a child lands in a flash map
  nobody prints: the act succeeds and says nothing. That is how the tag
  timeline thanked people for a report they never saw acknowledged.

  `VutuvWeb.LayoutHTML.embedded_flash/1` is the way in — a `<.portal>` that
  teleports the child's own toasts into that tray. These fail the build when a
  layoutless LiveView gains a flash without it.

  A page that IS a LiveView (`ControllerHelpers.render_live/3` or a routed
  `live/4`) is not covered and needs nothing: it brings the app layout itself,
  and its flash has always shown.
  """
  use ExUnit.Case, async: true

  # Helpers that put a flash into the socket they are handed, so a LiveView
  # reaches one without spelling `put_flash` itself. Two lists because the
  # distinction is a judgement: a flash on the way to a `redirect/2` is printed
  # by the NEXT page's layout and needs no portal. The second test fails if a
  # third such helper appears, so neither list can go quietly stale.
  @flashing_helpers [VutuvWeb.Live.RemotePostActions]
  @redirecting_helpers [VutuvWeb.Live.InitAssigns]

  test "a layoutless LiveView that can flash reaches the layout's tray" do
    for module <- layoutless_liveviews(),
        source = File.read!(source_path(module)),
        flashes?(source) do
      assert source =~ "embedded_flash", """
      #{inspect(module)} renders no layout of its own, so its flash never
      reaches the #toast-tray in app.html.heex — the act succeeds silently.

      Either render `<LayoutHTML.embedded_flash id="..." flash={@flash} />`
      somewhere in it, or say what happened another way (an inline notice next
      to the thing, or the thing itself visibly changing).
      """
    end
  end

  test "every helper that flashes on a LiveView's behalf is accounted for" do
    found =
      Enum.filter(app_modules(), fn module ->
        path = source_path(module)

        String.starts_with?(path, "lib/vutuv_web/live/") and
          not function_exported?(module, :__live__, 0) and
          String.contains?(File.read!(path), "put_flash(")
      end)

    assert Enum.sort(found) == Enum.sort(@flashing_helpers ++ @redirecting_helpers), """
    A module under lib/vutuv_web/live puts a flash into a socket it is handed,
    and this test does not know whether that flash stays on the page (list it in
    @flashing_helpers, and every layoutless caller then needs an
    `embedded_flash`) or rides a redirect (@redirecting_helpers).
    """
  end

  # Only this app's web modules, and loaded — `function_exported?/3` answers
  # false for a module nobody has touched yet, and loading all ~790 of them to
  # find seven views costs more than the rest of the file put together.
  defp app_modules do
    :vutuv
    |> Application.spec(:modules)
    |> Enum.filter(
      &(String.starts_with?(Atom.to_string(&1), "Elixir.VutuvWeb.") and Code.ensure_loaded?(&1))
    )
  end

  defp layoutless_liveviews do
    Enum.filter(app_modules(), fn module ->
      function_exported?(module, :__live__, 0) and module.__live__()[:kind] == :view and
        !module.__live__()[:layout]
    end)
  end

  defp flashes?(source) do
    String.contains?(source, "put_flash(") or
      Enum.any?(@flashing_helpers, &String.contains?(source, inspect(&1)))
  end

  defp source_path(module) do
    module.module_info(:compile)[:source] |> to_string() |> Path.relative_to_cwd()
  end
end

defmodule VutuvWeb.EmbeddedLiveViewLayoutTest do
  @moduledoc """
  A LiveView that a page embeds with `live_render/3` must carry no layout.

  `use VutuvWeb, :live_view` brings the `:app` layout, which is right for a
  LiveView that is the whole page and wrong for one inside a page: the child
  then draws a second top bar and a second footer inside its host's card. It
  happened twice, to the reference check panel and to the investor page's
  reach card, and both times only a look at the page showed it, because every
  test mounts the child on its own. Such a child uses
  `use VutuvWeb, :embedded_live_view` instead.

  The list is read from the source rather than typed here, so a new embed is
  checked the moment it is written. It sees every `live_render(<anything>,
  VutuvWeb.…)` under `lib/vutuv_web`; an embed that names its module through
  an alias or a variable is not seen. `VutuvWeb.ControllerHelpers.render_live/3`
  is one of those on purpose: the LiveViews it renders are whole pages and
  need the layout.
  """
  use ExUnit.Case, async: true

  @embed ~r/live_render\(\s*[@\w]+,\s*(VutuvWeb\.[\w.]+)/

  @embedded_views "lib/vutuv_web/**/*.{heex,ex}"
                  |> Path.wildcard()
                  |> Enum.map(&File.read!/1)
                  |> Enum.filter(&String.contains?(&1, "live_render("))
                  |> Enum.flat_map(&Regex.scan(@embed, &1, capture: :all_but_first))
                  |> List.flatten()
                  |> Enum.uniq()
                  |> Enum.map(&Module.concat([&1]))

  test "finds the embedded LiveViews it is meant to guard" do
    assert VutuvWeb.InvestorsReachLive in @embedded_views
    assert VutuvWeb.ShellLive in @embedded_views
  end

  test "no LiveView embedded in a page brings a layout of its own" do
    with_layout =
      for view <- @embedded_views,
          Code.ensure_loaded!(view),
          layout = view.__live__()[:layout],
          layout not in [nil, false],
          do: {view, layout}

    assert with_layout == []
  end
end

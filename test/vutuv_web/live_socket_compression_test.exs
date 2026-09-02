defmodule VutuvWeb.LiveSocketCompressionTest do
  @moduledoc """
  The LiveView socket negotiates permessage-deflate (`compress: true` on the
  `/live` socket in `VutuvWeb.Endpoint`).

  Pinned because it is the single largest lever on what a page costs and the
  easiest one to lose in a refactor of the socket line: the feed's join for
  `@wintermeyer` (34 cards, measured 2026-09-02 with Bandit's frame counters)
  sent 530,711 bytes over the socket uncompressed and 55,299 compressed —
  the uncompressed figure is more than every picture on the page together,
  and nginx cannot compress a websocket for us, after the upgrade it only
  passes frames through.
  """
  use ExUnit.Case, async: true

  test "the LiveView socket compresses its frames" do
    {"/live", Phoenix.LiveView.Socket, opts} =
      Enum.find(VutuvWeb.Endpoint.__sockets__(), fn {path, _module, _opts} -> path == "/live" end)

    assert opts[:websocket][:compress] == true
    # The frame cap and the session hand-over stay as they were.
    assert opts[:websocket][:max_frame_size] == 1_000_000
    assert Keyword.has_key?(opts[:websocket][:connect_info], :session)
  end
end

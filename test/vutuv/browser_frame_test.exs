defmodule Vutuv.BrowserFrameTest do
  @moduledoc """
  The "whole browser" look: every screenshot is wrapped in a browser window
  frame (title bar with traffic-light buttons and an address bar showing the
  URL) composited above the captured page. These tests lock the geometry and
  guard the long-URL truncation path so compositing never crashes.
  """
  use ExUnit.Case, async: true

  alias Vutuv.BrowserFrame

  setup do
    src = Path.join(System.tmp_dir!(), "page_#{System.unique_integer([:positive])}.png")
    out = Path.join(System.tmp_dir!(), "frame_#{System.unique_integer([:positive])}.png")
    {:ok, page} = Image.new(200, 150, color: [180, 180, 180])
    {:ok, _} = Image.write(page, src)

    on_exit(fn ->
      File.rm(src)
      File.rm(out)
    end)

    {:ok, src: src, out: out}
  end

  test "wraps the page in a chrome bar of the page width", %{src: src, out: out} do
    assert {:ok, ^out} = BrowserFrame.wrap(src, "https://example.com", out)

    {:ok, framed} = Image.open(out)
    assert Image.width(framed) == 200
    assert Image.height(framed) == 150 + BrowserFrame.chrome_height()
  end

  test "produces a valid PNG", %{src: src, out: out} do
    assert {:ok, ^out} = BrowserFrame.wrap(src, "https://example.com", out)
    assert {:ok, _} = Image.open(out)
    assert File.read!(out) |> binary_part(0, 8) == <<137, 80, 78, 71, 13, 10, 26, 10>>
  end

  test "a very long URL does not crash compositing", %{src: src, out: out} do
    long = "https://example.com/" <> String.duplicate("very-long-path-segment/", 40)
    assert {:ok, ^out} = BrowserFrame.wrap(src, long, out)
    assert {:ok, framed} = Image.open(out)
    assert Image.width(framed) == 200
  end
end

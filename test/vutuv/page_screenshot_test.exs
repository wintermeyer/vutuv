defmodule Vutuv.PageScreenshotTest do
  @moduledoc """
  capture/2 shells out to Chromium and must never raise, even when the binary
  is missing or the page hangs. A capture that crashed the caller would leave
  the broken flag unset and (historically) orphaned Chromium processes behind.
  """
  # Not async: these tests set the global `:chromium_path` application env.
  use ExUnit.Case, async: false

  setup do
    prev = Application.get_env(:vutuv, :chromium_path)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:vutuv, :chromium_path, prev),
        else: Application.delete_env(:vutuv, :chromium_path)
    end)

    :ok
  end

  test "returns an error tuple (never raises) when the configured binary is missing" do
    Application.put_env(:vutuv, :chromium_path, "/nonexistent/definitely-not-chromium")
    out = Path.join(System.tmp_dir!(), "ps_#{System.unique_integer([:positive])}.png")

    assert {:error, _reason} = Vutuv.PageScreenshot.capture("https://example.com", out)
    refute File.exists?(out)
  end
end

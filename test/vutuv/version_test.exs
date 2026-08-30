defmodule Vutuv.VersionTest do
  @moduledoc """
  The application version is the date of the commit being built, never a
  number somebody edits (why: the comment above `version/0` in `mix.exs`). A
  hand-written `version: "…"` line fails the first test, because it cannot
  equal the commit date.
  """

  use ExUnit.Case, async: true

  alias Vutuv.MixProject

  test "the version is the commit date of this checkout" do
    {iso, 0} = System.cmd("git", ["log", "-1", "--format=%cs"])
    assert Mix.Project.config()[:version] == MixProject.calver(String.trim(iso))
    # The value changes without mix.exs changing, so the generated .app file
    # has to follow it, or NodeInfo would keep reporting the previous date.
    assert to_string(Application.spec(:vutuv, :vsn)) == Mix.Project.config()[:version]
  end

  test "calver/1 drops leading zeros, which Version rejects" do
    assert MixProject.calver("2026-08-05") == "2026.8.5"
    assert MixProject.calver("2026-12-31") == "2026.12.31"
    assert {:ok, _} = Version.parse(MixProject.calver("2026-08-05"))
    assert Version.parse("2026.08.05") == :error
  end
end

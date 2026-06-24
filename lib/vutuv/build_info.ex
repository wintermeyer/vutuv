defmodule Vutuv.BuildInfo do
  @moduledoc """
  When this release was compiled, and therefore (close enough) deployed.

  Production deploys are blue/green from a *fresh* CI checkout: `actions/checkout`
  wipes the gitignored `_build`, so every deploy recompiles from scratch and the
  attribute below captures the build instant. The value is frozen into the BEAM
  at compile time, so it survives process restarts within a release and only
  moves on the next deploy. The compile happens a couple of minutes before
  traffic actually switches, so the footer reads the build instant rather than
  the exact cut-over - close enough for "when did this go live".
  """

  alias Vutuv.BerlinTime

  @built_at DateTime.truncate(DateTime.utc_now(), :second)

  @doc "The UTC instant this release was compiled."
  @spec built_at() :: DateTime.t()
  def built_at, do: @built_at

  @doc """
  The build instant (defaulting to the compile time) as a Europe/Berlin wall
  clock date, `DD.MM.YYYY`. The footer pairs it with `deployed_time/1` inside a
  gettext message so each locale supplies its own connective ("um … Uhr" / "at
  …") rather than baking German into the value.
  """
  @spec deployed_date(DateTime.t()) :: String.t()
  def deployed_date(utc \\ @built_at) do
    utc
    |> BerlinTime.naive()
    |> Calendar.strftime("%d.%m.%Y")
  end

  @doc """
  The build instant (defaulting to the compile time) as a Europe/Berlin wall
  clock time, `HH:MM`. See `deployed_date/1`.
  """
  @spec deployed_time(DateTime.t()) :: String.t()
  def deployed_time(utc \\ @built_at) do
    utc
    |> BerlinTime.naive()
    |> Calendar.strftime("%H:%M")
  end
end

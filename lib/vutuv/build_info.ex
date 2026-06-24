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
  A UTC instant (defaulting to the build time) as Europe/Berlin wall clock,
  formatted `HH:MM DD.MM.YYYY` for the footer.
  """
  @spec deployed_at(DateTime.t()) :: String.t()
  def deployed_at(utc \\ @built_at) do
    utc
    |> BerlinTime.naive()
    |> Calendar.strftime("%H:%M %d.%m.%Y")
  end
end

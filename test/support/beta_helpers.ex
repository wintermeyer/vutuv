defmodule Vutuv.BetaHelpers do
  @moduledoc """
  A stand-in beta feature for the tests of `Vutuv.Beta` and /settings/beta.
  It replaces the registry through the `:beta_features_override` env, which
  only `Vutuv.Beta.features/0` reads; the env is global, so every module
  calling this must be `async: false`.
  """

  alias Vutuv.Beta.Feature
  alias Vutuv.ExternalTagHelpers

  @features [
    %Feature{
      key: :test_feature,
      since: ~D[2026-10-01],
      title: "Test feature",
      description: "For everybody who switched on beta."
    }
  ]

  @doc "Swap the registry for `features` (the stand-in by default) for this test."
  def with_beta_features(features \\ @features),
    do: ExternalTagHelpers.put_config(:beta_features_override, features)
end

defmodule Vutuv.BetaHelpers do
  @moduledoc """
  Two stand-in beta features, one per audience, for the tests of `Vutuv.Beta`
  and /settings/beta. They replace the registry through the
  `:beta_features_override` env, which only `Vutuv.Beta.features/0` reads;
  the env is global, so every module calling this must be `async: false`.
  """

  alias Vutuv.Beta.Feature
  alias Vutuv.ExternalTagHelpers

  @features [
    %Feature{
      key: :test_member_feature,
      audience: :members,
      since: ~D[2026-10-01],
      title: "Member feature",
      description: "For everybody who wants it."
    },
    %Feature{
      key: :test_admin_feature,
      audience: :admins,
      since: ~D[2026-10-01],
      title: "Admin feature",
      description: "For admins who want it."
    }
  ]

  @doc "Swap the registry for `features` (the two stand-ins by default) for this test."
  def with_beta_features(features \\ @features),
    do: ExternalTagHelpers.put_config(:beta_features_override, features)
end

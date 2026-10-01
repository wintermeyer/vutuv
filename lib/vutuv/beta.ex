defmodule Vutuv.Beta do
  @moduledoc """
  Beta features: new behaviour that only members who switched on beta at
  /settings/beta get, before it is switched on for everybody.

  One switch per member (`users.beta?`) covers every beta feature, and it
  works the same for every member, admins included. Visitors who are not
  signed in never get a beta feature. How to add, graduate or drop one is in
  `docs/architecture/beta-features.md`.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts.User
  alias Vutuv.Beta.Feature

  # The registry, in display order. Titles and descriptions are msgids
  # (`gettext_noop/1` marks them for extraction) and are only translated in
  # `current/0`, so `enabled?/2` on a hot render path never translates
  # anything. An entry reads:
  #
  #     %Feature{
  #       key: :new_composer,
  #       since: ~D[2026-10-01],
  #       title: gettext_noop("New composer"),
  #       description: gettext_noop("Write posts in the redesigned editor.")
  #     }
  @registry []

  @doc """
  Every beta feature, untranslated. Tests swap in their own list through the
  `:beta_features_override` application env.
  """
  @spec features() :: [Feature.t()]
  def features, do: Application.get_env(:vutuv, :beta_features_override, @registry)

  @doc "Every beta feature with its title and description translated, for the settings page."
  @spec current() :: [Feature.t()]
  def current do
    for feature <- features() do
      %{
        feature
        | title: Gettext.gettext(VutuvWeb.Gettext, feature.title),
          description: Gettext.gettext(VutuvWeb.Gettext, feature.description)
      }
    end
  end

  @doc """
  Whether `user` gets the beta feature `key`: they switched on beta. Raises
  `ArgumentError` for a key the registry does not know, so a typo or a call
  left behind after graduation fails the suite instead of answering `false`
  in production.
  """
  @spec enabled?(User.t() | nil, atom) :: boolean
  def enabled?(user, key) when is_atom(key) do
    unless Enum.any?(features(), &(&1.key == key)), do: raise_unknown(key)

    match?(%User{beta?: true}, user)
  end

  defp raise_unknown(key) do
    raise ArgumentError,
          "unknown beta feature #{inspect(key)}; add it to Vutuv.Beta's registry, " <>
            "or remove the call if it graduated"
  end
end

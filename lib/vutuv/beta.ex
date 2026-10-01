defmodule Vutuv.Beta do
  @moduledoc """
  Beta features: new behaviour a member switches on for themselves at
  /settings/beta before it is switched on for everybody.

  Nobody gets one for who they are, admins included: an `:admins` feature is
  only *offered* to admins, and each of them still ticks it. Visitors who are
  not signed in never get one. How to add, graduate or drop a feature is in
  `docs/architecture/beta-features.md`.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts.User
  alias Vutuv.Beta.Feature
  alias Vutuv.Repo

  # The registry, in display order. Titles and descriptions are msgids
  # (`gettext_noop/1` marks them for extraction) and are only translated in
  # `available/1`, so `enabled?/2` on a hot render path never translates
  # anything. An entry reads:
  #
  #     %Feature{
  #       key: :new_composer,
  #       audience: :members,
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

  @doc "The features `user` may switch on, translated; none for a visitor."
  @spec available(User.t() | nil) :: [Feature.t()]
  def available(nil), do: []

  def available(%User{} = user) do
    for feature <- features(), offered?(feature, user) do
      %{
        feature
        | title: Gettext.gettext(VutuvWeb.Gettext, feature.title),
          description: Gettext.gettext(VutuvWeb.Gettext, feature.description)
      }
    end
  end

  @doc """
  Whether `user` gets the beta feature `key`: it is offered to them and they
  switched it on. Raises `ArgumentError` for a key the registry does not know,
  so a typo or a call left behind after graduation fails the suite instead of
  answering `false` in production.
  """
  @spec enabled?(User.t() | nil, atom) :: boolean
  def enabled?(user, key) when is_atom(key) do
    feature = Enum.find(features(), &(&1.key == key)) || raise_unknown(key)

    case user do
      %User{beta_features: chosen} -> offered?(feature, user) and Atom.to_string(key) in chosen
      nil -> false
    end
  end

  @doc """
  Store the features `user` switched on, given as the keys a form submits.
  Anything not offered to them (an unknown key, an admin feature for a
  member) is dropped, and so are the keys of features that no longer exist.
  """
  @spec choose(User.t(), [binary]) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def choose(%User{} = user, keys) when is_list(keys) do
    chosen =
      for feature <- features(),
          offered?(feature, user),
          key = Atom.to_string(feature.key),
          key in keys,
          do: key

    user
    |> Ecto.Changeset.change(beta_features: chosen)
    |> Repo.update()
  end

  defp offered?(%Feature{audience: :members}, %User{}), do: true
  defp offered?(%Feature{audience: :admins}, %User{admin?: admin?}), do: admin? == true

  defp raise_unknown(key) do
    raise ArgumentError,
          "unknown beta feature #{inspect(key)}; add it to Vutuv.Beta's registry, " <>
            "or remove the call if it graduated"
  end
end

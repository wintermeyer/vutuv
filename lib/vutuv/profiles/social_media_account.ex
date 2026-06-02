defmodule Vutuv.Profiles.SocialMediaAccount do
  @moduledoc false

  use VutuvWeb, :model

  alias PhoenixHTMLHelpers.Link, as: HTMLLink

  schema "social_media_accounts" do
    field(:provider, :string)
    field(:value, :string)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  @required_fields ~w(provider value)a
  @optional_fields ~w()a

  @accepted_providers ~w(Facebook Twitter Google+ Instagram Youtube Snapchat LinkedIn XING GitHub)

  base_urls = [
    {"Facebook", "http://facebook.com/"},
    {"Twitter", "http://twitter.com/"},
    {"Instagram", "http://instagram.com/"},
    {"Youtube", "http://youtube.com/channel/"},
    {"Snapchat", nil},
    {"LinkedIn", "https://www.linkedin.com/in/"},
    {"XING", "https://www.xing.com/profile/"},
    {"GitHub", "https://github.com/"}
  ]

  display_rules = [
    {"Facebook", ""},
    {"Twitter", "@"},
    {"Google+", "+"},
    {"Instagram", "@"},
    {"Youtube", ""},
    {"Snapchat", ""},
    {"LinkedIn", ""},
    {"XING", ""},
    {"GitHub", ""}
  ]

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned
  with no validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
    |> validate_required([:provider, :value])
    |> unique_constraint(:value_provider, message: "Someone has already claimed this account")
    |> update_change(:value, &parse_value/1)
    |> validate_change(:value, &validate_parse/2)
    |> validate_format(:value, ~r/^@?[A-z0-9-\.]*$/u)
    |> validate_inclusion(:provider, @accepted_providers)
  end

  def parse_value(value) do
    value
    |> String.replace(~r/^(http:\/\/)?(www\.)?\w*\.[a-z]*\/$/u, "")
    |> String.replace(~r/^@?/, "")
    |> String.split(~r/\//, trim: true)
    |> List.last()
  end

  def validate_parse(_, value) do
    if value, do: [], else: [value: {"Invalid account name", []}]
  end

  # This generates special display rule matches
  for {provider, pretext} <- display_rules do
    def get_display(%__MODULE__{provider: unquote(provider), value: value}),
      do: unquote(pretext) <> value
  end

  def get_display(_), do: ""

  # This generates special url rule matches
  for url <- base_urls do
    case url do
      {provider, nil} ->
        def social_media_link(%__MODULE__{provider: unquote(provider), value: value}), do: value

      {provider, url} ->
        def social_media_link(%__MODULE__{provider: unquote(provider), value: value} = account) do
          HTMLLink.link(get_display(account), to: unquote(url) <> value)
        end
    end
  end

  def social_media_link(_), do: ""

  # defp unique_constraint_error(%{"value" => value}) do
  #   unique_constraint_error(%{value: value})
  # end

  # defp unique_constraint_error(%{value: value}) do
  #   #account = Vutuv.Repo.one!(from s in __MODULE__, where: s.value == ^value, preload: [:user])
  #   "Someone has already claimed this account"
  # end

  # defp unique_constraint_error(_), do: ""
end

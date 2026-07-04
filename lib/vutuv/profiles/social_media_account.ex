defmodule Vutuv.Profiles.SocialMediaAccount do
  @moduledoc false

  use VutuvWeb, :model

  alias PhoenixHTMLHelpers.Link, as: HTMLLink

  schema "social_media_accounts" do
    field(:provider, :string)
    field(:value, :string)
    # The owner's chosen display order. Set programmatically (on create and via
    # the reorder/move actions), never cast from user params. NULLs sort last so
    # legacy rows fall back to creation order until reordered. See Vutuv.Ordering.
    field(:position, :integer)
    # Remote-fetch health for the inline social feeds (Vutuv.SocialFeed);
    # only meaningful for the feed-capable providers (Mastodon, Bluesky).
    # Managed by Vutuv.SocialFeed after each fetch, never cast from user
    # params: consecutive failures walk an escalating backoff ladder via
    # fetch_retry_at, and fetch_disabled_at switches updating off for good
    # (ladder exhausted, or a hard error such as the account no longer
    # existing). changeset/2 resets all three when the handle changes, so
    # fixing a typo re-enables the feed.
    field(:fetch_failures, :integer, default: 0)
    field(:fetch_retry_at, :utc_datetime)
    field(:fetch_disabled_at, :utc_datetime)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  @doc "Accounts in the owner's chosen order (see `Vutuv.Ordering`)."
  def ordered(query \\ __MODULE__), do: Vutuv.Ordering.by_position(query)

  @required_fields ~w(provider value)a
  @optional_fields ~w()a

  @accepted_providers ~w(Facebook Twitter Mastodon Bluesky Instagram Youtube Snapchat LinkedIn XING GitHub)

  @doc """
  The providers `changeset/2` accepts. The form's provider dropdown renders
  from this list so the two can never drift apart.
  """
  def accepted_providers, do: @accepted_providers

  # Providers whose profile URL is a fixed base plus the bare handle. Mastodon
  # is deliberately absent: it is federated, so the instance is part of the
  # handle and the link is built by mastodon_url/1 instead.
  base_urls = [
    {"Facebook", "http://facebook.com/"},
    {"Twitter", "http://twitter.com/"},
    {"Bluesky", "https://bsky.app/profile/"},
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
    {"Mastodon", "@"},
    {"Bluesky", ""},
    {"Instagram", "@"},
    {"Youtube", ""},
    {"Snapchat", ""},
    {"LinkedIn", ""},
    {"XING", ""},
    {"GitHub", ""}
  ]

  # A federated Mastodon handle: user@instance.tld.
  @mastodon_format ~r/^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$/u
  # A Bluesky handle: a lowercase domain (name.bsky.social, or a custom
  # domain) — the same shape Vutuv.Bluesky embeds in the AppView query.
  @bluesky_format ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned
  with no validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
    |> validate_required([:provider, :value])
    # varchar(255) column: an overlong handle must fail as a changeset error,
    # never as a raised Postgres 22001 (which 500ed the LinkedIn import).
    |> validate_length(:value, max: 255)
    |> unique_constraint(:value_provider, message: "Someone has already claimed this account")
    |> normalize_value()
    |> validate_value()
    |> validate_inclusion(:provider, @accepted_providers)
    |> reset_fetch_state()
  end

  # A changed handle is a different remote account, so any accumulated fetch
  # backoff or permanent deactivation no longer applies — the member fixing a
  # typo (or re-saving the row) re-enables the Mastodon feed.
  defp reset_fetch_state(changeset) do
    if get_change(changeset, :value) do
      change(changeset, fetch_failures: 0, fetch_retry_at: nil, fetch_disabled_at: nil)
    else
      changeset
    end
  end

  # Reduce whatever the member typed (a bare handle, a leading "@", a pasted
  # profile URL) down to the stored handle the provider's URL scheme needs.
  defp normalize_value(changeset) do
    case get_change(changeset, :value) do
      nil ->
        changeset

      value ->
        parsed =
          case get_field(changeset, :provider) do
            "Mastodon" -> parse_mastodon(value)
            "Bluesky" -> parse_bluesky(value)
            _ -> parse_value(value)
          end

        put_change(changeset, :value, parsed)
    end
  end

  def parse_value(value) do
    value
    |> String.replace(~r/^(http:\/\/)?(www\.)?\w*\.[a-z]*\/$/u, "")
    |> String.replace(~r/^@?/, "")
    |> String.split(~r/\//, trim: true)
    |> List.last()
  end

  # Mastodon is federated: the handle is user@instance, the profile lives at
  # https://instance/@user. Accept @user@instance, the bare user@instance, or a
  # pasted profile URL, and store user@instance.
  defp parse_mastodon(value) do
    case Regex.run(~r{^https?://([^/]+)/@?([^/@]+)}, String.trim(value)) do
      [_, instance, user] -> user <> "@" <> instance
      nil -> value |> String.trim() |> String.trim_leading("@")
    end
  end

  # A Bluesky handle is a domain, lowercase by definition. Accept a bare
  # handle, a leading "@", a pasted bsky.app profile URL, or a plain name
  # without a dot (assume the default .bsky.social namespace), and store the
  # full domain form Vutuv.Bluesky fetches by.
  defp parse_bluesky(value) do
    case parse_value(value) do
      handle when is_binary(handle) ->
        handle = String.downcase(handle)
        if String.contains?(handle, "."), do: handle, else: handle <> ".bsky.social"

      # Nothing extractable (e.g. a lone "@"); keep the input for
      # validate_value/1 to reject with the Bluesky-specific message.
      _ ->
        value
    end
  end

  defp validate_value(changeset) do
    provider = get_field(changeset, :provider)

    validate_change(changeset, :value, fn :value, value ->
      if valid_value?(provider, value), do: [], else: [value: invalid_message(provider)]
    end)
  end

  defp valid_value?("Mastodon", value), do: Regex.match?(@mastodon_format, value)
  defp valid_value?("Bluesky", value), do: Regex.match?(@bluesky_format, value)
  # Every other provider (LinkedIn, XING, Facebook, GitHub, …) accepts any
  # non-blank handle. These networks allow characters vutuv's own username
  # never will — German umlauts in a LinkedIn slug (sebastian-hädrich), dots,
  # apostrophes — so we only require that normalization left something behind
  # and defer the size limit to the varchar(255) cap. Issue #854 (from #748).
  defp valid_value?(_provider, value), do: is_binary(value) and String.trim(value) != ""

  defp invalid_message("Mastodon"),
    do: "Enter your full Mastodon handle, e.g. @user@instance.social"

  defp invalid_message("Bluesky"),
    do: "Enter your Bluesky handle, e.g. name.bsky.social"

  defp invalid_message(_), do: "Invalid account name"

  # This generates special display rule matches
  for {provider, pretext} <- display_rules do
    defp get_display(%__MODULE__{provider: unquote(provider), value: value}),
      do: unquote(pretext) <> value
  end

  defp get_display(_), do: ""

  # Mastodon's federated link; its URL scheme lives in mastodon_url/1 (the
  # instance is part of the handle, not a fixed base).
  def social_media_link(%__MODULE__{provider: "Mastodon"} = account),
    do: HTMLLink.link(get_display(account), to: url(account))

  # The rendered profile link; the provider → URL scheme knowledge lives
  # only in url/1 below. Providers without a canonical URL scheme (a nil
  # base) show the bare account name instead of a link.
  for {provider, base} <- base_urls do
    if base do
      def social_media_link(%__MODULE__{provider: unquote(provider)} = account),
        do: HTMLLink.link(get_display(account), to: url(account))
    else
      def social_media_link(%__MODULE__{provider: unquote(provider), value: value}), do: value
    end
  end

  def social_media_link(_), do: ""

  # The profile URL as a plain string (the bare value when the provider has
  # no canonical URL scheme, e.g. Snapchat) — the agent documents
  # (VutuvWeb.AgentDocs) need a string, not a rendered link.
  def url(%__MODULE__{provider: "Mastodon", value: value}), do: mastodon_url(value)

  for url <- base_urls do
    case url do
      {provider, nil} ->
        def url(%__MODULE__{provider: unquote(provider), value: value}), do: value

      {provider, url} ->
        def url(%__MODULE__{provider: unquote(provider), value: value}),
          do: unquote(url) <> value
    end
  end

  def url(_), do: ""

  # https://instance/@user from the stored user@instance handle.
  defp mastodon_url(value) do
    case String.split(value, "@", parts: 2, trim: true) do
      [user, instance] -> "https://" <> instance <> "/@" <> user
      _ -> ""
    end
  end
end

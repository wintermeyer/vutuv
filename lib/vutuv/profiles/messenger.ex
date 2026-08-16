defmodule Vutuv.Profiles.Messenger do
  @moduledoc """
  An online messenger a member lists on their profile (issue #949): Signal,
  WhatsApp, Telegram, Threema, Matrix or Session.

  Modelled on `Vutuv.Profiles.SocialMediaAccount` — a `provider` + `value` pair
  with a per-provider display order — but kept a distinct resource because a
  messenger contact is a direct line to reach someone, not a public social
  profile, and its address is usually *not* a phone number.

  Each provider knows how to turn its stored `value` into a **deep link** that
  opens the messenger straight at that contact (`url/1`), so a visitor can start
  a chat in one click. Signal and WhatsApp accept **either** a phone number or a
  username (both services offer usernames now): a phone-shaped value is validated
  and canonicalised through the very same `Vutuv.Phone` validator the phone-numbers
  section uses, while a username is kept as typed — so a valid handle is never
  rejected as "not a phone number". The other providers carry a service-specific
  id or username.

  Signal takes a **third** shape, its contact link (issue #1442): it is the only
  Signal address that names neither the phone number nor the username (the
  fragment carries an encrypted handle), and it can be reset inside the app at
  any time, so it is what a member reaches for who wants to be reachable without
  disclosing an identifier. `kind/1` is the single discriminator between the
  three shapes, and `label/1` is what a link to the contact says: a contact link
  has no address to show, so it reads as an action.
  """

  use VutuvWeb, :model

  # The `gettext/1` macro (not available in the shared `:model` block) so the
  # contact-link label is picked up by `mix gettext.extract`.
  use Gettext, backend: VutuvWeb.Gettext

  alias PhoenixHTMLHelpers.Link, as: HTMLLink
  alias Vutuv.Phone

  schema "messengers" do
    field(:provider, :string)
    field(:value, :string)
    # The owner's chosen display order. Set programmatically (on create and via
    # the reorder/move actions), never cast from user params. NULLs sort last so
    # legacy rows fall back to creation order until reordered. See Vutuv.Ordering.
    field(:position, :integer)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  @doc "Messengers in the owner's chosen order (see `Vutuv.Ordering`)."
  def ordered(query \\ __MODULE__), do: Vutuv.Ordering.by_position(query)

  # The accepted providers, in the order the form's dropdown lists them.
  @providers ~w(Signal WhatsApp Telegram Threema Matrix Session)

  # Providers whose value can be EITHER a phone number or a username (Signal and
  # WhatsApp both offer usernames now). A phone-shaped value is validated and
  # canonicalised through the phone validator; a username is kept as typed.
  @dual_providers ~w(Signal WhatsApp)

  # Providers whose contact may ALSO be given as a link, and the host that link
  # has to carry. Only Signal: its link is the one Signal address that discloses
  # neither the number nor the username. WhatsApp's `wa.me/qr/…` short link is
  # deliberately absent — WhatsApp shows the number in the chat regardless, so
  # storing it as a link would promise a privacy it does not deliver.
  @link_hosts %{"Signal" => "signal.me"}

  # Where a messenger address can hide inside a URL a member pasted into their
  # links, for `from_url/1`. Wider than @link_hosts, because most of these are
  # not stored as a link: a `t.me` address is the username inside it. `:link`
  # keeps the whole (canonicalised) URL, `:path` takes the first path segment,
  # `:fragment` the first fragment segment. Each is then handed to `changeset/2`,
  # which is what actually decides whether it is a valid address.
  @url_providers %{
    "signal.me" => {"Signal", :link},
    "t.me" => {"Telegram", :path},
    "threema.id" => {"Threema", :path},
    "matrix.to" => {"Matrix", :fragment}
  }

  @doc """
  The providers `changeset/2` accepts, in the order the form's dropdown lists
  them. The dropdown renders from this list so the two can never drift apart.
  """
  def accepted_providers, do: @providers

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned with no
  validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:provider, :value])
    |> validate_required([:provider, :value])
    |> validate_inclusion(:provider, @providers)
    |> update_change(:value, &String.trim/1)
    |> normalize_value()
    # varchar(255) column: an overlong value must fail as a changeset error, not
    # a raised Postgres 22001. Checked after normalization, which can only
    # shorten a value here.
    |> validate_length(:value, max: 255)
    |> unique_constraint([:user_id, :provider, :value],
      name: :messengers_user_id_provider_value_index,
      message: "You have already added this messenger"
    )
  end

  # Reduce whatever the member typed down to the stored form, and reject
  # anything that is not a valid address for the chosen provider. Runs on the
  # trimmed change, so nothing to do when the value was not changed.
  #
  # A link is recognised FIRST: a pasted `https://signal.me/#eu/…` carries
  # letters, so the username branch below would take it and reject it on `:` and
  # `/`, which is exactly how members ended up filing it under their webpage
  # links instead (issue #1442).
  defp normalize_value(changeset) do
    provider = get_field(changeset, :provider)

    case get_change(changeset, :value) do
      value when is_binary(value) ->
        cond do
          link_shaped?(provider, value) -> normalize_link(changeset, provider, value)
          provider in @dual_providers -> normalize_dual(changeset, value)
          true -> normalize_handle(changeset, provider, value)
        end

      _ ->
        changeset
    end
  end

  # Is the member trying to give a link at all? Only then does a failure deserve
  # the link error rather than "enter a phone number or a username". An explicit
  # scheme, or the provider's own host up front — a bare "signal.me" is none of
  # those and stays a (perfectly valid) username.
  defp link_shaped?(provider, value) do
    case Map.fetch(@link_hosts, provider) do
      {:ok, host} ->
        String.contains?(value, "://") or
          String.starts_with?(String.downcase(value), [
            host <> "/",
            host <> "#",
            "www." <> host <> "/",
            "www." <> host <> "#"
          ])

      :error ->
        false
    end
  end

  defp normalize_link(changeset, provider, value) do
    case canonical_link(provider, value) do
      {:ok, link} -> put_change(changeset, :value, link)
      :error -> add_error(changeset, :value, link_error(provider))
    end
  end

  defp link_error("Signal"), do: "Enter your Signal link, it starts with https://signal.me/#"

  # The stored form of a contact link: the provider's canonical host over https
  # plus the fragment, byte for byte. Everything else is dropped, because the
  # fragment IS the address (that is why it never reaches Signal's server) and a
  # query a share sheet appended is not part of it. Deliberately lenient about
  # what the fragment contains: the format has changed five times since 2022, so
  # a token grammar would only be the next thing to break.
  defp canonical_link(provider, value) do
    with {:ok, host} <- Map.fetch(@link_hosts, provider),
         %URI{host: given, fragment: fragment} <- URI.parse(with_scheme(String.trim(value))),
         true <- is_binary(given) and String.downcase(given) in [host, "www." <> host],
         true <- is_binary(fragment) and fragment != "" do
      {:ok, "https://" <> host <> "/#" <> fragment}
    else
      _ -> :error
    end
  end

  defp with_scheme(value) do
    if String.contains?(value, "://"), do: value, else: "https://" <> value
  end

  # Signal / WhatsApp accept a phone number OR a username. Only a phone-shaped
  # value (no letters) goes through the phone validator; a username is kept as
  # typed, so a valid handle is never rejected as "not a phone number".
  defp normalize_dual(changeset, value) do
    if phone_number_value?(value),
      do: normalize_phone(changeset, value),
      else: normalize_username(changeset, value)
  end

  # A phone number: reuse the phone-numbers validator so a typed number is
  # canonicalised to international `+country` format and junk is rejected — the
  # same behaviour (and stored shape) as the phone-numbers section.
  defp normalize_phone(changeset, value) do
    case Phone.normalize(value) do
      {:ok, normalized} -> put_change(changeset, :value, normalized)
      :error -> add_error(changeset, :value, "Please enter a valid phone number")
    end
  end

  # A Signal / WhatsApp username: letters/digits and . _ -, at least one letter
  # (so a stored username is never mistaken for a phone number), kept without a
  # leading "@". Deliberately lenient — the point is to accept a handle, not to
  # police each service's exact username grammar.
  defp normalize_username(changeset, value) do
    handle = String.trim_leading(value, "@")

    if handle =~ ~r/^[A-Za-z0-9._-]{2,64}$/ and handle =~ ~r/[A-Za-z]/,
      do: put_change(changeset, :value, handle),
      else: add_error(changeset, :value, "Enter a phone number or a username")
  end

  # What each provider's handle looks like once tidied, as `{pattern, message}`.
  # A table rather than four clauses of the same seven lines, so a new messenger
  # is a row plus a `tidy/2` clause and the four error sentences can be read
  # side by side:
  #
  #   * Telegram: a public @username, 5–32 of [A-Za-z0-9_], stored without the "@".
  #   * Threema: an 8-character ID of [A-Z0-9].
  #   * Matrix: a federated MXID @user:homeserver.
  #   * Session: a 66-character account ID (05 then 64 hex characters).
  @handle_rules %{
    "Telegram" => {~r/^[A-Za-z0-9_]{5,32}$/, "Enter your Telegram username, e.g. @yourname"},
    "Threema" => {~r/^[A-Z0-9]{8}$/, "Enter your 8-character Threema ID, e.g. ABCD1234"},
    "Matrix" => {~r/^@[^:\s]+:[^\s]+\.[^\s]+$/, "Enter your Matrix ID, e.g. @you:matrix.org"},
    "Session" => {~r/^05[0-9a-f]{64}$/, "Enter your 66-character Session ID"}
  }

  defp normalize_handle(changeset, provider, value) do
    case Map.fetch(@handle_rules, provider) do
      {:ok, {pattern, message}} ->
        handle = tidy(provider, value)

        if handle =~ pattern,
          do: put_change(changeset, :value, handle),
          else: add_error(changeset, :value, message)

      :error ->
        changeset
    end
  end

  # Spaces and a missing or stray "@" are typing, not a wrong handle, so each
  # provider's value is tidied into its stored shape before it is judged.
  defp tidy("Telegram", value), do: String.trim_leading(value, "@")
  defp tidy("Threema", value), do: value |> String.replace(" ", "") |> String.upcase()
  defp tidy("Matrix", value), do: prepend_at(String.trim(value))
  defp tidy("Session", value), do: value |> String.replace(~r/\s/, "") |> String.downcase()

  defp prepend_at("@" <> _ = id), do: id
  defp prepend_at(id), do: "@" <> id

  # A value is a phone number (rather than a username) exactly when it carries no
  # letter: phone numbers are digits + punctuation, while Signal/WhatsApp
  # usernames always contain a letter. Used both to route input (phone validator
  # vs username path) and to pick the deep-link scheme for a stored value.
  defp phone_number_value?(value), do: not Regex.match?(~r/[A-Za-z]/, value)

  @doc """
  Which of its provider's address shapes a stored value is:

    * `:link` — a contact link (`https://signal.me/#eu/…`), naming neither the
      member's phone number nor their username;
    * `:phone` — a phone number, canonicalised by `Vutuv.Phone`;
    * `:username` — a handle or a service-specific id.

  The single discriminator `url/1`, `display/1` and `label/1` branch on, so the
  three can never disagree about what they are looking at.
  """
  def kind(%__MODULE__{provider: provider, value: value}) do
    cond do
      contact_link?(provider, value) -> :link
      provider in @dual_providers and phone_number_value?(value) -> :phone
      true -> :username
    end
  end

  defp contact_link?(provider, value) when is_binary(value) do
    match?({:ok, _link}, canonical_link(provider, value))
  end

  defp contact_link?(_provider, _value), do: false

  @doc """
  The messenger a pasted URL is an address for, as `{provider, value}` ready for
  `changeset/2`, or `nil` when the URL is an ordinary webpage.

  Behind the links editor's "this belongs under Messengers" suggestion: a member
  whose messenger address was refused here files it as a webpage link instead
  (issue #1442), where it is neither in the right card nor a page worth
  screenshotting.
  """
  def from_url(url) when is_binary(url) do
    uri = URI.parse(with_scheme(String.trim(url)))
    host = uri.host |> to_string() |> String.downcase() |> String.replace_prefix("www.", "")

    case Map.fetch(@url_providers, host) do
      {:ok, {provider, source}} -> address_in(provider, source, uri)
      :error -> nil
    end
  end

  def from_url(_url), do: nil

  defp address_in(provider, :link, uri) do
    case canonical_link(provider, URI.to_string(uri)) do
      {:ok, link} -> {provider, link}
      :error -> nil
    end
  end

  defp address_in(provider, source, uri) do
    part = if source == :path, do: uri.path, else: uri.fragment

    case part |> to_string() |> String.split("/", trim: true) do
      [segment | _rest] -> {provider, segment}
      [] -> nil
    end
  end

  @doc """
  The deep link that opens the messenger straight at this contact, as a plain
  string — for the agent documents (`VutuvWeb.AgentDocs`) and the vCard `IMPP`
  lines, which need a string, not a rendered link. Yields `""` when there is no
  constructible web link (Session, or a Signal/WhatsApp **username** — those
  services have no public username resolver), and the bare contact is shown
  instead, like Snapchat in the social media section.
  """
  def url(%__MODULE__{provider: provider, value: value} = messenger) do
    # A contact link IS the link; there is nothing to construct.
    if kind(messenger) == :link, do: value, else: provider_url(provider, value)
  end

  def url(_), do: ""

  # WhatsApp click-to-chat wants bare E.164 digits, no "+"; only a phone number
  # has a link (a username has no public wa.me resolver).
  defp provider_url("WhatsApp", value) do
    if phone_number_value?(value),
      do: "https://wa.me/" <> String.replace(Phone.tel(value), "+", ""),
      else: ""
  end

  # Signal's phone deep link keeps the leading "+"; a username has no public link.
  defp provider_url("Signal", value) do
    if phone_number_value?(value), do: "https://signal.me/#p/" <> Phone.tel(value), else: ""
  end

  defp provider_url("Telegram", value), do: "https://t.me/" <> value
  defp provider_url("Threema", value), do: "https://threema.id/" <> value
  defp provider_url("Matrix", value), do: "https://matrix.to/#/" <> value
  defp provider_url(_provider, _value), do: ""

  @doc """
  The address itself, as a viewer would read it: a phone number spaced for
  reading (`Phone.display/1`), otherwise the stored handle, id or link
  unchanged. This is what the agent documents and the vCard carry, so it stays
  the address and never a caption — for the caption see `label/1`.
  """
  def display(%__MODULE__{value: value} = messenger) do
    if kind(messenger) == :phone, do: Phone.display(value), else: value
  end

  @doc """
  What a link to this contact says. A contact link has no address to show — its
  whole point is that it names neither the number nor the username, and its
  64-character token means nothing to a reader — so it reads as an action.
  Every other shape shows the address itself.
  """
  def label(%__MODULE__{} = messenger) do
    if kind(messenger) == :link, do: gettext("Open chat"), else: display(messenger)
  end

  @doc """
  The rendered profile link: `label/1` linked to `url/1`, or the bare label when
  the provider has no deep link (Session).
  """
  def messenger_link(%__MODULE__{} = messenger) do
    case url(messenger) do
      "" -> label(messenger)
      link -> HTMLLink.link(label(messenger), to: link, rel: "noopener noreferrer")
    end
  end
end

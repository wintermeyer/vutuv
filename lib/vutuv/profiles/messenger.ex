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
  """

  use VutuvWeb, :model

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
  defp normalize_value(changeset) do
    provider = get_field(changeset, :provider)

    case get_change(changeset, :value) do
      value when is_binary(value) ->
        if provider in @dual_providers,
          do: normalize_dual(changeset, value),
          else: normalize_handle(changeset, provider, value)

      _ ->
        changeset
    end
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

  # Telegram: a public @username, 5–32 of [A-Za-z0-9_]. Stored without the "@".
  defp normalize_handle(changeset, "Telegram", value) do
    handle = String.trim_leading(value, "@")

    if handle =~ ~r/^[A-Za-z0-9_]{5,32}$/,
      do: put_change(changeset, :value, handle),
      else: add_error(changeset, :value, "Enter your Telegram username, e.g. @yourname")
  end

  # Threema: an 8-character ID of [A-Z0-9] (spaces tolerated, case-folded up).
  defp normalize_handle(changeset, "Threema", value) do
    id = value |> String.replace(" ", "") |> String.upcase()

    if id =~ ~r/^[A-Z0-9]{8}$/,
      do: put_change(changeset, :value, id),
      else: add_error(changeset, :value, "Enter your 8-character Threema ID, e.g. ABCD1234")
  end

  # Matrix: a federated MXID @user:homeserver. A leading "@" is added if missing.
  defp normalize_handle(changeset, "Matrix", value) do
    id = prepend_at(String.trim(value))

    if id =~ ~r/^@[^:\s]+:[^\s]+\.[^\s]+$/,
      do: put_change(changeset, :value, id),
      else: add_error(changeset, :value, "Enter your Matrix ID, e.g. @you:matrix.org")
  end

  # Session: a 66-character account ID (starts with 05, then 64 hex chars).
  defp normalize_handle(changeset, "Session", value) do
    id = value |> String.replace(~r/\s/, "") |> String.downcase()

    if id =~ ~r/^05[0-9a-f]{64}$/,
      do: put_change(changeset, :value, id),
      else: add_error(changeset, :value, "Enter your 66-character Session ID")
  end

  defp normalize_handle(changeset, _provider, _value), do: changeset

  defp prepend_at("@" <> _ = id), do: id
  defp prepend_at(id), do: "@" <> id

  # A value is a phone number (rather than a username) exactly when it carries no
  # letter: phone numbers are digits + punctuation, while Signal/WhatsApp
  # usernames always contain a letter. Used both to route input (phone validator
  # vs username path) and to pick the deep-link scheme for a stored value.
  defp phone_number_value?(value), do: not Regex.match?(~r/[A-Za-z]/, value)

  @doc """
  The deep link that opens the messenger straight at this contact, as a plain
  string — for the agent documents (`VutuvWeb.AgentDocs`) and the vCard `IMPP`
  lines, which need a string, not a rendered link. Yields `""` when there is no
  constructible web link (Session, or a Signal/WhatsApp **username** — those
  services have no public username resolver), and the bare contact is shown
  instead, like Snapchat in the social media section.
  """
  # WhatsApp click-to-chat wants bare E.164 digits, no "+"; only a phone number
  # has a link (a username has no public wa.me resolver).
  def url(%__MODULE__{provider: "WhatsApp", value: value}) do
    if phone_number_value?(value),
      do: "https://wa.me/" <> String.replace(Phone.tel(value), "+", ""),
      else: ""
  end

  # Signal's phone deep link keeps the leading "+"; a username has no public link.
  def url(%__MODULE__{provider: "Signal", value: value}) do
    if phone_number_value?(value), do: "https://signal.me/#p/" <> Phone.tel(value), else: ""
  end

  def url(%__MODULE__{provider: "Telegram", value: value}), do: "https://t.me/" <> value
  def url(%__MODULE__{provider: "Threema", value: value}), do: "https://threema.id/" <> value
  def url(%__MODULE__{provider: "Matrix", value: value}), do: "https://matrix.to/#/" <> value
  def url(%__MODULE__{provider: "Session"}), do: ""
  def url(_), do: ""

  @doc """
  The value as shown to a viewer: a phone number spaced for reading
  (`Phone.display/1`), otherwise the stored handle/id unchanged.
  """
  def display(%__MODULE__{provider: provider, value: value}) do
    if provider in @dual_providers and phone_number_value?(value),
      do: Phone.display(value),
      else: value
  end

  @doc """
  The rendered profile link: the displayed value linked to `url/1`, or the bare
  displayed value when the provider has no deep link (Session).
  """
  def messenger_link(%__MODULE__{} = messenger) do
    case url(messenger) do
      "" -> display(messenger)
      link -> HTMLLink.link(display(messenger), to: link, rel: "noopener noreferrer")
    end
  end
end

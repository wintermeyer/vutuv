defmodule Vutuv.AccountEvents.AccountEvent do
  @moduledoc """
  One entry in a member's account-activity log (issue #1087).

  Append-only: there is no `updated_at`, no update changeset and no delete
  outside the retention sweep and the account cascade. `inserted_at` carries
  **microsecond** resolution on purpose — support has to be able to say "you
  changed this at 14:32:07", and two changes inside one second must still have
  an order.

  What a row may hold is decided by `Vutuv.AccountEvents`, not here: the kind
  must be a declared one and every `details` key must be whitelisted for that
  kind, which is what keeps secrets and private values out of a table that a
  backup, an admin page and a support conversation all touch. There is
  deliberately **no IP address** — the `ip_address` column is dropped in the
  release after this one (an N-1-safe expand/contract), and nothing reads or
  writes it any more.
  """

  use VutuvWeb, :model

  alias Vutuv.AccountEvents

  schema "account_events" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:actor_user, Vutuv.Accounts.User)

    field(:kind, :string)
    field(:factor, :string)
    field(:device, :string)
    field(:details, :map, default: %{})

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  The one write path. `user_id` and `actor_user_id` are set programmatically on
  the struct, never cast, and the kind / factor / details are validated against
  the registry in `Vutuv.AccountEvents` so an undeclared kind or an unexpected
  detail key can never reach the table.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:kind, :factor, :device, :details])
    |> validate_required([:kind])
    |> validate_inclusion(:kind, AccountEvents.kinds())
    |> validate_inclusion(:factor, AccountEvents.factors())
    |> validate_length(:device, max: 200)
    |> validate_details()
  end

  # The details map is checked against the kind's own key whitelist. An
  # undeclared key is an error rather than a silent drop: a caller that tried to
  # log something the registry never sanctioned is a bug worth seeing in the
  # logs, and the alternative (dropping it) would hide exactly the mistake this
  # guard exists to catch.
  defp validate_details(changeset) do
    kind = get_field(changeset, :kind)
    details = get_field(changeset, :details) || %{}

    cond do
      not is_map(details) ->
        add_error(changeset, :details, "must be a map")

      kind == nil or not AccountEvents.kind?(kind) ->
        changeset

      true ->
        allowed = AccountEvents.detail_keys(kind)
        unknown = details |> Map.keys() |> Enum.reject(&(to_string(&1) in allowed))

        if unknown == [],
          do: put_change(changeset, :details, normalize_details(details)),
          else: add_error(changeset, :details, "has undeclared keys: #{Enum.join(unknown, ", ")}")
    end
  end

  # Stored as JSONB, so it comes back with string keys whatever went in; write
  # string keys too, and every value gets capped/flattened to something a JSON
  # column and a rendered table can both hold.
  defp normalize_details(details) do
    Map.new(details, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_value(value) when is_binary(value), do: String.slice(value, 0, 255)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)

  defp normalize_value(value) when is_map(value) and not is_struct(value),
    do: normalize_details(value)

  defp normalize_value(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp normalize_value(value), do: value |> to_string() |> String.slice(0, 255)
end

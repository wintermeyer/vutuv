defmodule VutuvWeb.UnsubscribeToken do
  @moduledoc """
  The signed capability behind "switch a notification email off without a
  login": every notification email carries it in its `List-Unsubscribe`
  header (RFC 8058 one-click) and as a footer link.

  A token names the user id and the single preference field it may switch off,
  nothing else, so the long lifetime is safe: unsubscribe links in old mail
  must keep working. The field is verified against `Vutuv.Accounts.User`'s
  allowlist (`email_pref_fields/0`), so possessing a token can never flip an
  arbitrary column — only a real notification-email preference.

  Legacy tokens (issued before the granular preferences existed) name only the
  id; they resolve to the original `:notification_emails?` switch so links in
  already-sent mail keep working.
  """

  alias Vutuv.Accounts.User

  @salt "unsubscribe"
  @max_age 60 * 60 * 24 * 365

  @doc "Signs a token for the master unread-messages switch (legacy shape)."
  def sign(%User{id: id}),
    do: Phoenix.Token.sign(VutuvWeb.Endpoint, @salt, id)

  @doc "Signs a token that switches off one named preference field."
  def sign(%User{id: id}, field) when is_atom(field),
    do: Phoenix.Token.sign(VutuvWeb.Endpoint, @salt, {id, Atom.to_string(field)})

  @doc """
  Verifies a token. Returns `{:ok, user_id, field}` with the (allowlisted)
  preference field the token may switch off, or `{:error, reason}`. A legacy
  id-only token resolves to `:notification_emails?`.
  """
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(VutuvWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, id} when is_binary(id) -> {:ok, id, :notification_emails?}
      {:ok, {id, field}} when is_binary(id) and is_binary(field) -> verify_field(id, field)
      {:ok, _other} -> {:error, :invalid}
      error -> error
    end
  end

  def verify(_token), do: {:error, :invalid}

  defp verify_field(id, field) do
    allowed = Enum.map(User.email_pref_fields(), &Atom.to_string/1)

    if field in allowed do
      {:ok, id, String.to_existing_atom(field)}
    else
      {:error, :invalid}
    end
  end

  @doc "The absolute unsubscribe URL for the master unread-messages switch."
  def url(%User{} = user), do: public_url() <> "unsubscribe/" <> sign(user)

  @doc "The absolute unsubscribe URL that switches off the named preference."
  def url(%User{} = user, field) when is_atom(field),
    do: public_url() <> "unsubscribe/" <> sign(user, field)

  defp public_url, do: Application.get_env(:vutuv, VutuvWeb.Endpoint)[:public_url]
end

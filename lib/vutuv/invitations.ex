defmodule Vutuv.Invitations do
  @moduledoc """
  Member-to-non-member invitations.

  A member fills the sign-up fields plus an email address (and, optionally, a
  personal note, an auto-follow flag and the invitation's language). We send a
  localized email whose link opens the sign-up form prefilled with that data, so
  the invited person only has to confirm.

  Privacy and abuse guards:

    * We store **only a SHA-256 hash** of the normalized (trimmed + downcased)
      address, never the plaintext — a DB leak can't reveal who was invited.
    * A `unique_index` on the hash enforces **one invitation per address,
      site-wide**; a repeat is silently a no-op and returns the *same* outcome as
      a fresh send, so the caller can never learn an address was already invited.
    * A **per-inviter daily cap** (`daily_cap/0`) protects sender reputation.

  `record_visit/1` stamps `visited_at` the first time the invited person opens
  the link; `apply_auto_follow/2` makes the inviter follow the new member once
  they register, when the invitation asked for it.
  """
  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.BerlinTime
  alias Vutuv.Invitations.Invitation
  alias Vutuv.Invitations.InvitationRequest
  alias Vutuv.Invitations.PrefillToken
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Repo
  alias Vutuv.Token

  # Default most-a-single-member-may-send in one Berlin calendar day. The live
  # value comes from config (:invitation_daily_cap), env-overridable per
  # installation via INVITATION_DAILY_CAP — see daily_cap/0.
  @default_daily_cap 50

  @doc "A blank form-backing changeset for the invite form."
  def change_invitation_request(attrs \\ %{}) do
    InvitationRequest.changeset(%InvitationRequest{}, attrs)
  end

  @doc "The per-inviter daily invitation cap (configurable per installation)."
  def daily_cap, do: Application.get_env(:vutuv, :invitation_daily_cap, @default_daily_cap)

  @doc """
  Validate the form, enforce the daily cap, and — if the address is new — record
  the invitation and mail it. Never reveals whether the address was invited
  before.

  Returns (the `preview` is a `%{html_body, subject, to_name, to_email}` map of
  the built email, so the caller can show the inviter exactly what the recipient
  receives — it is identical whether or not we actually sent, so it never
  betrays that the address had already been invited):

    * `{:ok, :sent, preview}` — a new address; the email is on its way.
    * `{:ok, :already_invited, preview}` — a repeat; nothing sent (shown as `:sent`).
    * `{:error, :rate_limited}` — the inviter hit today's cap.
    * `{:error, %Ecto.Changeset{}}` — the form is invalid.
  """
  def deliver_invitation(%User{} = inviter, attrs) do
    changeset = InvitationRequest.changeset(%InvitationRequest{}, attrs)

    if changeset.valid? do
      request = Ecto.Changeset.apply_changes(changeset)

      if invites_sent_today(inviter) >= daily_cap() do
        {:error, :rate_limited}
      else
        deliver_valid(inviter, request)
      end
    else
      {:error, Map.put(changeset, :action, :insert)}
    end
  end

  defp deliver_valid(%User{} = inviter, %InvitationRequest{} = request) do
    # Build the email up front so the "sent" page can show the inviter exactly
    # what the recipient receives. The preview is identical whether or not we
    # actually send it, so it never leaks that the address had been invited.
    email = build_invitation_email(inviter, request)

    status =
      case insert_invitation(inviter, request) do
        {:ok, _invitation} ->
          Emailer.deliver(email)
          :sent

        {:error, _changeset} ->
          # The lone constraint is the email_hash unique index, so a failure
          # here can only mean the address was invited before. Same outcome as
          # a fresh send — we never leak the difference.
          :already_invited
      end

    {:ok, status, email_preview(email)}
  end

  defp insert_invitation(%User{} = inviter, %InvitationRequest{} = request) do
    %Invitation{user_id: inviter.id}
    |> Invitation.changeset(%{
      email_hash: hash_email(request.email),
      locale: request.locale,
      auto_follow: request.auto_follow
    })
    |> Repo.insert()
  end

  defp build_invitation_email(%User{} = inviter, %InvitationRequest{} = request) do
    Emailer.invitation_email(%{
      inviter: inviter,
      to_email: request.email,
      locale: request.locale,
      message: presence(request.message),
      prefill: prefill_params(request)
    })
  end

  # What the "sent" page needs to show the inviter: the full HTML body (rendered
  # in a sandboxed iframe) plus the header lines.
  defp email_preview(%Swoosh.Email{} = email) do
    {to_name, to_email} = hd(email.to)

    %{html_body: email.html_body, subject: email.subject, to_name: to_name, to_email: to_email}
  end

  # The sign-up fields we carry in the invite link. Packed into a single compact
  # `i=` token by Vutuv.Invitations.PrefillToken (the emailer builds the URL);
  # the landing page reads it back with prefill_from_params/1 below.
  defp prefill_params(%InvitationRequest{} = request) do
    %{
      "gender" => request.gender,
      "first_name" => request.first_name,
      "last_name" => request.last_name,
      "tags" => request.tag_list,
      "email" => request.email
    }
  end

  @doc """
  The sign-up prefill for the landing page, from the request's query params.

  Reads the compact `i=` invitation token (`Vutuv.Invitations.PrefillToken`)
  when present, and otherwise falls back to the spelled-out
  `first_name` / `last_name` / `gender` / `tags` / `email` params — the layout
  older invitation links still sitting in inboxes use. Returns a map with those
  string keys; missing fields are simply absent.
  """
  def prefill_from_params(params) when is_map(params) do
    case params[PrefillToken.param()] do
      token when is_binary(token) and token != "" ->
        PrefillToken.decode(token)

      _ ->
        Map.take(params, ~w(gender first_name last_name email tags))
    end
  end

  @doc """
  How many invitations `inviter` has sent today (Europe/Berlin calendar day),
  the figure the daily cap is checked against.
  """
  def invites_sent_today(%User{id: id}), do: invites_sent_today(id)

  def invites_sent_today(user_id) when is_binary(user_id) do
    {from_utc, to_utc} = BerlinTime.day_bounds_utc(BerlinTime.today())

    Repo.aggregate(
      from(i in Invitation,
        where: i.user_id == ^user_id and i.inserted_at >= ^from_utc and i.inserted_at < ^to_utc
      ),
      :count
    )
  end

  @doc """
  Stamp `visited_at` the first time the invited person opens the prefilled link.

  Scoped to `is_nil(visited_at)`, so only the first visit counts; a no-op when
  the address is blank or was never invited. Safe to call on every landing-page
  render.
  """
  def record_visit(email) when is_binary(email) do
    if normalize_email(email) == "" do
      :ok
    else
      now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      from(i in Invitation, where: i.email_hash == ^hash_email(email) and is_nil(i.visited_at))
      |> Repo.update_all(set: [visited_at: now])

      :ok
    end
  end

  def record_visit(_), do: :ok

  @doc """
  When `new_user` registers with an address that was invited with the
  auto-follow flag set, make the inviter follow them. A no-op otherwise (unknown
  address, flag off, or the inviter is gone).
  """
  def apply_auto_follow(email, %User{} = new_user) when is_binary(email) do
    if normalize_email(email) != "" do
      Invitation
      |> where([i], i.email_hash == ^hash_email(email))
      |> Repo.one()
      |> maybe_follow(new_user)
    end

    :ok
  end

  def apply_auto_follow(_, _), do: :ok

  defp maybe_follow(%Invitation{auto_follow: true, user_id: inviter_id}, %User{id: new_id})
       when is_binary(inviter_id) and inviter_id != new_id do
    # Best effort: a blocked/duplicate edge just means no follow.
    Vutuv.Social.follow(inviter_id, new_id)
  end

  defp maybe_follow(_, _), do: :ok

  @doc "The stored hash of an address: SHA-256 of its normalized form."
  def hash_email(email), do: email |> normalize_email() |> Token.hash_token()

  @doc "Trim and downcase an address, the form we hash and compare."
  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  def normalize_email(_), do: ""

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end
end

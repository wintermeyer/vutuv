defmodule Vutuv.LoginCodes do
  @moduledoc """
  The power-user login codes of issue #912: a code from an **authenticator
  app** (RFC 6238 TOTP) or from a printed **one-time code list**
  ("Kennwortliste"), both accepted in the login PIN field as alternatives to
  the emailed PIN.

  Like a passkey (`Vutuv.Credentials`), these are *alternative first factors*
  for a faster or email-independent return login — never the root of trust.
  Enrolment lives behind the logged-in settings area, reachable only by a
  member who already proved they own their email by typing a PIN at least
  once, and the email-PIN flow stays untouched: a member who sets nothing up
  never sees any of this, and a member who loses their app or list simply
  keeps logging in by email.

  Wiring: `Vutuv.Accounts.check_login_code/2` calls `redeem_login_code/2`
  only after the emailed-PIN check failed, so all failure messages, attempt
  counters and lockouts stay exactly the PIN flow's — alternate codes only
  ever add a success path.

    * **TOTP** — one `UserTotp` row per member. `start_totp_enrollment/1`
      mints the secret server-side (it must never ride in the client-readable
      signed session cookie), the member scans the QR code and proves the app
      works with a first code (`confirm_totp/2`); only then is the row usable
      for login. Verification accepts the current and the previous 30-second
      window (clock drift) and hands `last_used_at` to NimbleTOTP as `since:`
      so a code can never be replayed.
    * **One-time code list** — a batch of `ListCode` rows in the canonical
      `XXXX-XXXX` form (unambiguous alphabet, no `0/O/1/I/L`). Each code logs
      the member in once (consumed atomically); the list can be viewed again,
      regenerated (replacing every code) or deleted in the settings area.
  """

  import Ecto.Query

  alias Vutuv.Accounts.Email
  alias Vutuv.Accounts.User
  alias Vutuv.LoginCodes.ListCode
  alias Vutuv.LoginCodes.UserTotp
  alias Vutuv.Repo

  # The RFC 6238 time-step; also the clock-drift grace (one previous window).
  @totp_period 30

  # How many codes a fresh one-time code list holds.
  @list_size 10

  # The code alphabet: digits and letters without the look-alikes 0/O, 1/I/L,
  # so a printed or handwritten list survives re-typing. 31 symbols, 8 chars
  # per code ≈ 39 bits — far beyond the login flow's 3-attempts-per-window
  # lockout budget.
  @code_alphabet ~c"23456789ABCDEFGHJKMNPQRSTUVWXYZ"
  @code_length 8

  # ── Authenticator app (TOTP) ──

  @doc "The member's TOTP enrolment row (confirmed or pending), or nil."
  def get_totp(%User{} = user), do: Repo.get_by(UserTotp, user_id: user.id)

  @doc "Whether the member has a confirmed authenticator app."
  def totp_enabled?(%User{} = user) do
    Repo.exists?(from(t in UserTotp, where: t.user_id == ^user.id and not is_nil(t.confirmed_at)))
  end

  @doc """
  Begins (or resumes) the authenticator-app enrolment: returns the pending
  `%UserTotp{}` whose secret the setup page renders as a QR code. Idempotent —
  reopening the page keeps the same pending secret, so a QR code scanned just
  before a reload stays valid. Returns `{:error, :already_enabled}` once a
  confirmed enrolment exists (it must be turned off first, so an established
  secret cannot be silently replaced).
  """
  def start_totp_enrollment(%User{} = user) do
    case get_totp(user) do
      %UserTotp{confirmed_at: nil} = pending ->
        {:ok, pending}

      %UserTotp{} ->
        {:error, :already_enabled}

      nil ->
        # on_conflict: :nothing + re-read keeps a two-tab race from raising on
        # the unique user_id index; whichever tab won, both show its secret.
        %UserTotp{user_id: user.id, secret: NimbleTOTP.secret()}
        |> Repo.insert!(on_conflict: :nothing, conflict_target: [:user_id])

        {:ok, get_totp(user)}
    end
  end

  @doc """
  Completes the enrolment: the member types the code their app currently
  shows, proving the scan worked, and the row becomes usable for login.
  Returns `{:ok, totp}`, `{:error, :invalid_code}` on a wrong code, or
  `{:error, :not_started}` when there is nothing pending.
  """
  def confirm_totp(%User{} = user, code) do
    case get_totp(user) do
      %UserTotp{confirmed_at: nil} = pending ->
        if totp_code_valid?(pending, normalize(code)) do
          now = DateTime.utc_now(:second)

          {:ok,
           pending
           |> Ecto.Changeset.change(confirmed_at: now, last_used_at: now)
           |> Repo.update!()}
        else
          {:error, :invalid_code}
        end

      %UserTotp{} = confirmed ->
        {:ok, confirmed}

      nil ->
        {:error, :not_started}
    end
  end

  @doc "Turns the authenticator app off (pending or confirmed). Email-PIN login is unaffected."
  def disable_totp(%User{} = user) do
    Repo.delete_all(from(t in UserTotp, where: t.user_id == ^user.id))
    :ok
  end

  # Login-time TOTP verification: confirmed enrolments only. On success the
  # verified moment is stored so the same code is refused for the rest of its
  # window (NimbleTOTP's `since:`).
  defp verify_totp(%User{} = user, code) do
    with %UserTotp{confirmed_at: %DateTime{}} = totp <- get_totp(user),
         true <- totp_code_valid?(totp, code) do
      totp
      |> Ecto.Changeset.change(last_used_at: DateTime.utc_now(:second))
      |> Repo.update!()

      :ok
    else
      _ -> :error
    end
  end

  # Accept the current window and, for clock drift on the member's device, the
  # previous one. `since:` (the last successful use) makes both replay-proof.
  defp totp_code_valid?(%UserTotp{secret: secret, last_used_at: since}, code) do
    NimbleTOTP.valid?(secret, code, since: since) or
      NimbleTOTP.valid?(secret, code, time: System.os_time(:second) - @totp_period, since: since)
  end

  # ── One-time code list ("Kennwortliste") ──

  @doc "The member's one-time code list in generation order (used ones included)."
  def list_codes(%User{} = user) do
    Repo.all(from(c in ListCode, where: c.user_id == ^user.id, order_by: [asc: c.id]))
  end

  @doc "Whether the member has a one-time code list (any row, used or not)."
  def list_codes?(%User{} = user) do
    Repo.exists?(from(c in ListCode, where: c.user_id == ^user.id))
  end

  @doc "How many codes on the member's list are still unused."
  def unused_list_codes_count(%User{} = user) do
    Repo.one(
      from(c in ListCode,
        where: c.user_id == ^user.id and is_nil(c.used_at),
        select: count(c.id)
      )
    )
  end

  @doc """
  Generates a fresh one-time code list for the member, replacing any existing
  list (used and unused codes alike), and returns the new `%ListCode{}` rows.
  """
  def generate_list_codes(%User{} = user) do
    codes =
      Stream.repeatedly(&random_code/0)
      |> Stream.uniq()
      |> Enum.take(@list_size)

    now = NaiveDateTime.utc_now(:second)

    rows =
      Enum.map(codes, fn code ->
        %{
          id: Vutuv.UUIDv7.generate(),
          user_id: user.id,
          code: code,
          inserted_at: now,
          updated_at: now
        }
      end)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.delete_all(from(c in ListCode, where: c.user_id == ^user.id))
        Repo.insert_all(ListCode, rows)
      end)

    list_codes(user)
  end

  @doc "Deletes the member's one-time code list."
  def delete_list_codes(%User{} = user) do
    Repo.delete_all(from(c in ListCode, where: c.user_id == ^user.id))
    :ok
  end

  # Redeem one unused list code. The consuming UPDATE is guarded on
  # `used_at IS NULL`, so a double submit of the same code races to a single
  # winner and every later attempt fails.
  defp redeem_list_code(%User{} = user, code) do
    unused =
      Repo.all(
        from(c in ListCode,
          where: c.user_id == ^user.id and is_nil(c.used_at),
          select: {c.id, c.code}
        )
      )

    match =
      Enum.find(unused, fn {_id, stored} ->
        Plug.Crypto.secure_compare(String.replace(stored, "-", ""), code)
      end)

    with {id, _stored} <- match,
         {1, _} <-
           Repo.update_all(
             from(c in ListCode, where: c.id == ^id and is_nil(c.used_at)),
             set: [used_at: DateTime.utc_now(:second)]
           ) do
      :ok
    else
      _ -> :error
    end
  end

  # ── The login seam ──

  @doc """
  Tries `input` as one of the member's alternative login codes: a 6-digit
  code goes to the authenticator app (the emailed PIN has the same shape but
  was already checked — and failed — before this is called), an 8-character
  code to the one-time list. Whitespace and hyphens are ignored and letters
  upcased, so "abcd efgh", "ABCD-EFGH" and a Google-Authenticator-style
  "123 456" all read correctly. Returns `:ok` or `:error` — deliberately the
  same `:error` for every failure shape, so the caller's fallback (the PIN
  check's own result) is all a client ever sees.
  """
  def redeem_login_code(%User{} = user, input) when is_binary(input) do
    code = normalize(input)

    cond do
      code =~ ~r/^\d{6}$/ -> verify_totp(user, code)
      byte_size(code) == @code_length -> redeem_list_code(user, code)
      true -> :error
    end
  end

  def redeem_login_code(_user, _input), do: :error

  @doc """
  Whether the account owning `email` has any alternative login code set up (a
  confirmed authenticator app or an unused list code). Used by the PIN screen
  to show its one-line reminder only to members who actually enrolled —
  mirroring `Vutuv.Credentials.passkey_for_email?/1`, including its deliberate
  cost: the reminder reveals that the typed address has an enrolled account.
  A `false` covers both "nothing set up" and "no such account".
  """
  def any_for_email?(email) when is_binary(email) do
    email = String.downcase(email)

    totp =
      from(t in UserTotp,
        join: e in Email,
        on: e.user_id == t.user_id,
        where: e.value == ^email and not is_nil(t.confirmed_at)
      )

    list =
      from(c in ListCode,
        join: e in Email,
        on: e.user_id == c.user_id,
        where: e.value == ^email and is_nil(c.used_at)
      )

    Repo.exists?(totp) or Repo.exists?(list)
  end

  def any_for_email?(_email), do: false

  # ── Display helpers (the enrolment page) ──

  @doc """
  The otpauth:// provisioning URI the setup page renders as a QR code. The
  issuer is the installation's host (from the endpoint URL, never a literal
  vutuv.de), so the entry is recognizable in the member's authenticator app
  on any installation.
  """
  def otpauth_uri(%User{} = user, %UserTotp{secret: secret}) do
    issuer = URI.parse(VutuvWeb.Endpoint.url()).host
    NimbleTOTP.otpauth_uri("#{issuer}:#{user.username}", secret, issuer: issuer)
  end

  @doc "The secret in Base32, grouped in fours, for apps that can't scan the QR code."
  def manual_entry_secret(%UserTotp{secret: secret}) do
    secret
    |> Base.encode32(padding: false)
    |> String.replace(~r/.{4}(?=.)/, "\\0 ")
  end

  # ── Helpers ──

  defp normalize(input) when is_binary(input) do
    input
    |> String.replace(~r/[\s-]/, "")
    |> String.upcase()
  end

  # One random code ("XXXX-XXXX"), rejection-sampled so the 31-symbol alphabet
  # is drawn uniformly.
  defp random_code do
    chars = random_chars(@code_length, [])
    {left, right} = Enum.split(chars, 4)
    List.to_string(left) <> "-" <> List.to_string(right)
  end

  defp random_chars(0, acc), do: acc

  defp random_chars(n, acc) do
    <<byte>> = :crypto.strong_rand_bytes(1)
    limit = 256 - rem(256, length(@code_alphabet))

    if byte < limit do
      random_chars(n - 1, [Enum.at(@code_alphabet, rem(byte, length(@code_alphabet))) | acc])
    else
      random_chars(n, acc)
    end
  end
end

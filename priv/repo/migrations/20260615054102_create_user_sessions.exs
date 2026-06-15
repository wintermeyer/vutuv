defmodule Vutuv.Repo.Migrations.CreateUserSessions do
  use Ecto.Migration

  def change do
    # One server-side row per signed-in browser session, so a member can see
    # where their account is logged in and revoke a single device (issue #794)
    # and so a noteworthy login can be detected and emailed about (issue #786).
    #
    # Purely additive, N-1 backward compatible: the currently-deployed release
    # ignores the table and keeps logging in via the cookie's user_id. The new
    # release treats a cookie that carries no session token as a valid legacy
    # session (VutuvWeb.Plug.ConfigureSession lazily mints a row for it), so the
    # deploy never logs anybody out.
    #
    # Only the SHA-256 hash of the per-session lookup token is stored (like
    # api_tokens.token_hash) — a leaked dump mints no usable session cookie. The
    # raw token lives only in the signed session cookie.
    create table(:user_sessions) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:token_hash, :string, null: false)
      # The User-Agent string (device/browser) and the source IP captured at
      # login, plus an optional coarse geo string (best-effort, see Vutuv.Geo).
      add(:user_agent, :text)
      add(:ip_address, :string)
      add(:approx_location, :string)
      # When this device was last seen on a request (bumped at most once a
      # minute, like api_tokens.last_used_at).
      add(:last_seen_at, :utc_datetime)
      add(:revoked_at, :utc_datetime)

      # inserted_at is "first signed in"; updated_at rides along.
      timestamps()
    end

    create(unique_index(:user_sessions, [:token_hash]))
    create(index(:user_sessions, [:user_id]))
  end
end

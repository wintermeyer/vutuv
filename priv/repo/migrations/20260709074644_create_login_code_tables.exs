defmodule Vutuv.Repo.Migrations.CreateLoginCodeTables do
  use Ecto.Migration

  def change do
    # The power-user login codes of issue #912 (see Vutuv.LoginCodes): a code
    # from an authenticator app (TOTP) or from a printed one-time code list
    # ("Kennwortliste") works in the login PIN field as an alternative to the
    # emailed PIN. Both are enrolled from the logged-in settings area, so the
    # email PIN stays the only way to bootstrap an account.
    #
    # Purely additive and N-1 backward compatible: the currently-deployed
    # release ignores both tables; the email-PIN login is untouched.

    # One row per member who set up an authenticator app. The row is created
    # unconfirmed when the setup page mints the secret (so the secret never
    # rides in the client-readable signed session cookie) and becomes usable
    # for login only once the member proves the app works by typing a code
    # (confirmed_at set).
    create table(:user_totps) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      # The shared RFC 6238 secret (raw bytes). It must be readable to verify
      # codes, so it is stored as-is — like the peppered PIN hashes, the DB
      # plus app secrets are the trust boundary.
      add(:secret, :binary, null: false)
      add(:confirmed_at, :utc_datetime)
      # The last successful verification, handed to NimbleTOTP as `since:` so
      # a code can never be replayed within its validity window.
      add(:last_used_at, :utc_datetime)

      timestamps()
    end

    create(unique_index(:user_totps, [:user_id]))

    # One row per code on the member's one-time code list. A login consumes
    # its row (used_at set); regenerating the list replaces all rows.
    create table(:login_list_codes) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      # Canonical "XXXX-XXXX" form (an unambiguous alphabet, no 0/O/1/I/L).
      add(:code, :string, null: false)
      add(:used_at, :utc_datetime)

      timestamps()
    end

    create(index(:login_list_codes, [:user_id]))
    create(unique_index(:login_list_codes, [:user_id, :code]))
  end
end

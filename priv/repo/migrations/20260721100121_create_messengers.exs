defmodule Vutuv.Repo.Migrations.CreateMessengers do
  use Ecto.Migration

  # Online messengers a member lists on their profile (issue #949): Signal,
  # WhatsApp, Telegram, Threema, Matrix, Session, … Its own resource rather than
  # a phone number, because most messenger addresses are not phone numbers
  # (Threema IDs, Matrix @user:server handles, Session IDs). A plain additive
  # table, so it ships N-1 backward compatible in one deploy.
  def change do
    create table(:messengers) do
      add(:user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false)
      # The messenger service ("Signal", "WhatsApp", "Matrix", …), validated in
      # Vutuv.Profiles.Messenger against its accepted-provider list.
      add(:provider, :string, null: false)
      # The address on that service: a phone number for Signal/WhatsApp
      # (canonicalised through the phone validator), otherwise the service's own
      # id/username (Telegram @name, 8-char Threema ID, Matrix MXID, Session ID).
      add(:value, :string, null: false)
      # The owner's chosen display order (see Vutuv.Ordering). Nullable + NULLs
      # last, matching the other orderable profile sections.
      add(:position, :integer)

      timestamps()
    end

    create(index(:messengers, [:user_id]))
    # A member never lists the exact same messenger twice; a global unique index
    # is deliberately avoided (two people can legitimately never share a WhatsApp
    # number, and enforcing it site-wide would leak who holds which contact).
    create(unique_index(:messengers, [:user_id, :provider, :value]))
  end
end

defmodule Vutuv.Repo.Migrations.CreateQualifications do
  use Ecto.Migration

  def change do
    create table(:qualifications) do
      add(:user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false)
      # The credential's name ("AWS Solutions Architect – Associate"), required.
      add(:name, :string, null: false)
      # "certification" or "license" — validated in Vutuv.Profiles.Qualification,
      # kept a plain string here. A LinkedIn import lands everything as a
      # certification (LinkedIn carries no licence/cert signal).
      add(:kind, :string, null: false, default: "certification")
      # The issuing body ("Amazon Web Services", "Landesärztekammer Hessen").
      add(:issuer, :string)
      # When it was awarded (month optional). A cert has no school period, so
      # unlike an education entry it carries a single "awarded" date …
      add(:awarded_month, :integer)
      add(:awarded_year, :integer)
      # … and, unlike a degree, an optional expiry (certs and licences lapse).
      add(:expires_month, :integer)
      add(:expires_year, :integer)
      # The credential/licence number printed on the badge ("AWS-1234").
      add(:credential_id, :string)
      # A verify / badge link. Display-only, never fetched server-side (SSRF),
      # scheme-validated to http(s) so it can't smuggle a javascript: href.
      add(:url, :string)
      # Reserved for issue #857 (folding education degrees into this table).
      # Always NULL for now; ON DELETE SET NULL so a deleted education leaves the
      # qualification intact rather than cascading it away. No index yet — it
      # would only index NULLs; #857 adds one when it starts populating it.
      add(:education_id, references(:educations, on_delete: :nilify_all, type: :binary_id))

      timestamps()
    end

    create(index(:qualifications, [:user_id]))
  end
end

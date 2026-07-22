defmodule Vutuv.Repo.Migrations.AddQualificationDocuments do
  use Ecto.Migration

  # A member may upload one proof document (PDF or image) per certificate /
  # license (the follow-up to issue #1005). Plain additive columns, so the
  # deploy is N-1 safe.
  def change do
    alter table(:qualifications) do
      # The uploaded file's original client filename (display + download name);
      # nil = no document.
      add(:document, :string)
      # sha256(original bytes)[0..11] — binds moderation verdicts to the exact
      # bytes and makes the served URLs immutable (cache-safe).
      add(:document_fingerprint, :string)
      add(:document_content_type, :string)
      # Size of the original in bytes, for the "PDF · 1.2 MB" label.
      add(:document_size, :bigint)
      # AI image moderation state: "pending" | "approved" (nil = no document).
      add(:document_moderation, :string)
      # When the owner ticked the "this becomes public" consent checkbox —
      # uploads are impossible without it, so this is the recorded proof of
      # consent.
      add(:document_consented_at, :utc_datetime)
    end
  end
end

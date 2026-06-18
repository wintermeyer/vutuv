defmodule Vutuv.Repo.Migrations.AddImageFingerprints do
  use Ecto.Migration

  # Content fingerprint (first 12 hex of sha256 of the uploaded original) baked
  # into the served filename so the browser download carries it and the URL is
  # immutable (`<handle>-<version>-<fingerprint>.avif`). Nullable: a row stays
  # nil until the regenerator has written its new-scheme files, and a nil
  # fingerprint means "serve the legacy URL exactly as before" — so this add is
  # backward-compatible (N-1): the previous release ignores the column.
  def change do
    alter table(:users) do
      add :avatar_fingerprint, :string
      add :cover_fingerprint, :string
    end
  end
end

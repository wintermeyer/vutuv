defmodule Vutuv.Repo.Migrations.AddInvoiceEmailToAds do
  use Ecto.Migration

  # Which of the booker's addresses the invoice goes to. A member may hold
  # several (work and private), and until now the operator mail simply named
  # whichever came first, which is a guess about somebody's accounting.
  #
  # Nullable and never written by the release this deploy replaces, so that one
  # keeps working; a booking made before this simply has none, and the operator
  # mail falls back to the account's first address as it always did.
  def change do
    alter table(:ads) do
      add(:invoice_email, :string)
    end
  end
end

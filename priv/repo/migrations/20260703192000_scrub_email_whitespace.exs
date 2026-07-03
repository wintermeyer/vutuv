defmodule Vutuv.Repo.Migrations.ScrubEmailWhitespace do
  use Ecto.Migration

  # Data-only repair of the legacy whitespace addresses (946 rows in prod at
  # the time of writing): trims edge whitespace and removes whitespace from
  # the domain part where the result is a valid, non-colliding address. Pure
  # UPDATE, no schema change, idempotent - trivially N-1 safe. The logic lives
  # (tested) in Vutuv.Accounts.EmailScrub; deploys run migrations from the new
  # release, so the module is available here.
  def up do
    fixed = Vutuv.Accounts.EmailScrub.scrub_whitespace()
    IO.puts("EmailScrub: repaired #{fixed} whitespace address(es)")
  end

  def down, do: :ok
end

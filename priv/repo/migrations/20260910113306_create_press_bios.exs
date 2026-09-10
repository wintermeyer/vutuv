defmodule Vutuv.Repo.Migrations.CreatePressBios do
  use Ecto.Migration

  # The three bios a member writes for their Media Kit (issue #2101): a short
  # one for a caption, a medium one for the end of an article, and the long
  # form. One row per owner, three columns, because the three are written and
  # saved as one thing.
  #
  # A table of its own rather than three columns on `users`: that table already
  # carries 112 fields and is read on every feed row, every post card and every
  # mention card, while these three are prose of up to 20,000 characters each
  # that exactly three surfaces read (the Media Kit page, its documents and the
  # editor). Postgres would keep them out of line in TOAST, but the row still
  # travels with every `select *` Ecto builds.
  #
  # `organization_id` is deliberately **absent**: #2101 asks for a member's
  # bios, and a page's boilerplate is a product decision nobody has taken. The
  # shape leaves room for it — one nullable column, the
  # `images_press_kit_has_one_owner` check constraint beside it and
  # `Vutuv.Identity.Query.party_is/2`, which is what the press pictures on
  # `images` already do — and nothing here has to change to get there.
  #
  # Purely additive, so it is N-1 compatible: the currently deployed release
  # neither reads nor writes this table.
  def change do
    create table(:press_bios) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      # `:text`, not varchar(255): each is Markdown prose exactly as a post
      # body is, and `Vutuv.PressKit.max_bio_length/0` bounds all three at the
      # post body's own 20,000 characters. The word counts the editor shows
      # (about 50, about 150, none) are guidance, never a limit, so the column
      # must admit a member who writes eighty words in the short one.
      add(:short, :text)
      add(:medium, :text)
      add(:long, :text)

      timestamps()
    end

    # One row per member, which is what makes the write an upsert with no read
    # in front of it.
    create(unique_index(:press_bios, [:user_id]))
  end
end

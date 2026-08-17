defmodule Vutuv.Repo.Migrations.AddParentOrganizationToPostReplies do
  @moduledoc """
  A member may answer a post published in a page's name (issue #1336 closed the
  reading side #1334 was waiting for), so the companion row that names a reply's
  parent needs the second kind of parent author beside the first.

  `parent_author_id` is not there to find the parent — `parent_post_id` does
  that. It is there so a reply **outlives** its parent with the author still
  nameable: both set means the parent is alive, only `parent_post_id` NULL means
  "a now-deleted post by X", both NULL means the account is gone too and no name
  is retained. Without a page-shaped half of that pair, every answer to a page's
  post would fall straight to the nameless state the moment the page deleted the
  post, and the page's own activity list would have to reach through the deleted
  parent to find the answers written to it.

  So: a nullable `parent_organization_id` beside `parent_author_id`, nilifying
  the same way, with the same `(id, inserted_at)` index behind the derived
  "somebody answered your post" list. **No CHECK constraint**, deliberately, and
  this is where the row differs from the nullable pairs in `posts` and
  `fediverse_followers`: those name an owner and exactly one of them must be
  set, while here *both* being NULL is a legitimate, reachable state (the parent
  and its author are both gone) — a CHECK for "exactly one" would reject the
  very rows the nilify is designed to leave behind.

  N-1 safe: purely additive. The previous release never writes the column and
  never reads it, and its own reply gate refuses a page's post outright, so it
  cannot produce a row that would want one.
  """
  use Ecto.Migration

  def change do
    alter table(:post_replies) do
      add(
        :parent_organization_id,
        references(:organizations, type: :binary_id, on_delete: :nilify_all)
      )
    end

    # Backs the page's derived "X answered a post of yours" activity source,
    # the twin of the `parent_author_id` index the member feed reads.
    create(index(:post_replies, [:parent_organization_id, :inserted_at]))
  end
end

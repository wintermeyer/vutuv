defmodule Vutuv.Repo.Migrations.AddOrganizationToModerationCases do
  @moduledoc """
  Which page a moderation case is about (issue #2120).

  The case already names the one member who answers for the content
  (`owner_id`, the strike ladder). It could not say that the content belonged
  to a **page**, so the only way to tell a page's other owners that a picture
  had been taken down would have been a union of subqueries over posts, images
  and attachments on the notifications hot path. One denormalised column
  answers it in a join, written at the single place a case is minted
  (`Vutuv.Moderation.new_case_changeset/2`).

  N-1: a nullable column, an index and a backfill are additions the currently
  deployed release neither reads nor writes.
  """
  use Ecto.Migration

  def up do
    alter table(:moderation_cases) do
      add(:organization_id, references(:organizations, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:moderation_cases, [:organization_id]))

    # The cases that already exist. Without this, a case opened before the
    # deploy stays invisible to every owner but the claimer for the rest of its
    # life — and an open one is exactly where the 72 hours are still running.
    # Plain SQL with no parameters: a `$1::uuid` placeholder would demand the
    # raw 16-byte form of an id (see `.claude/rules/ecto.md`), and there is
    # nothing here to pin.
    flush()

    execute("""
    UPDATE moderation_cases c SET organization_id = p.organization_id
    FROM posts p
    WHERE c.content_type = 'post' AND c.content_id = p.id
      AND p.organization_id IS NOT NULL
    """)

    execute("""
    UPDATE moderation_cases c SET organization_id = i.organization_id
    FROM images i
    WHERE c.content_type = 'image' AND c.content_id = i.id
      AND i.organization_id IS NOT NULL
    """)

    execute("""
    UPDATE moderation_cases c SET organization_id = p.organization_id
    FROM attachments a
    JOIN posts p ON p.id = a.post_id
    WHERE c.content_type = 'attachment' AND c.content_id = a.id
      AND p.organization_id IS NOT NULL
    """)

    execute("""
    UPDATE moderation_cases c SET organization_id = c.content_id
    WHERE c.content_type = 'organization'
      AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = c.content_id)
    """)
  end

  def down do
    alter table(:moderation_cases) do
      remove(:organization_id)
    end
  end
end

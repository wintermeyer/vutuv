defmodule Vutuv.Repo.DeleteNonsenseTagsTest do
  @moduledoc """
  Covers the one-time cleanup migration `delete_nonsense_tags`.

  A fresh test database holds none of the rows the migration is aimed at, so
  running the migration here would prove nothing (the real check is a run
  against `vutuv1_dev`, see CLAUDE.md). What this file guards instead are the
  properties that can silently break: that the statement removes exactly the
  listed names and nothing beside them, that an absent name is a no-op rather
  than a failure, that a tag an operator wired a newsletter group to survives,
  and that the list itself never regrows the entries that were deliberately
  taken out of it.

  The test executes the migration's own `delete_sql/0` rather than a copy, so
  the two cannot drift apart.

  `async: false`: the module is loaded from `priv/repo/migrations` at runtime
  with `Code.require_file/1`, which is global.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Newsletters.NewsletterGroup
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag

  @migration Vutuv.Repo.Migrations.DeleteNonsenseTags

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      [file] = Path.wildcard("priv/repo/migrations/*_delete_nonsense_tags.exs")
      Code.require_file(file)
    end

    :ok
  end

  defp run_delete(names), do: Repo.query!(@migration.delete_sql(), [names])

  describe "the list itself" do
    test "holds no duplicates and no blank entries" do
      names = @migration.nonsense_tags()

      assert names == Enum.uniq(names)
      refute Enum.any?(names, &(String.trim(&1) == ""))
    end

    test "keeps the single-letter language names out" do
      # `c` alone carries three-digit member usage; `r` and `d` are languages
      # too. They look like noise and are not, so they must never creep back in.
      for language <- ~w(c r d) do
        refute language in @migration.nonsense_tags(),
               "#{language} is a programming language, not a nonsense tag"
      end
    end
  end

  describe "delete_sql/0" do
    test "removes a listed tag and takes its memberships with it" do
      [name | _] = @migration.nonsense_tags()
      tag = insert(:tag, name: name)
      user_tag = Repo.insert!(%UserTag{user_id: insert(:user).id, tag_id: tag.id})

      assert %{num_rows: 1} = run_delete([name])

      refute Repo.get(Tag, tag.id)
      refute Repo.get(UserTag, user_tag.id), "user_tags should cascade with the tag"
    end

    test "leaves every tag that is not on the list alone" do
      [name | _] = @migration.nonsense_tags()
      doomed = insert(:tag, name: name)
      keeper = insert(:tag, name: "Elixir")

      run_delete([name])

      refute Repo.get(Tag, doomed.id)
      assert Repo.get(Tag, keeper.id)
    end

    test "a name no tag carries is a no-op, not a failure" do
      # The expected outcome on any installation that never collected these
      # strings: nothing matches, nothing raises, the migration moves on.
      assert %{num_rows: 0} = run_delete(["a name no installation has ever used"])
    end

    test "skips a tag a newsletter group points at" do
      # `newsletter_groups.tag_id` is ON DELETE SET NULL, so deleting such a tag
      # would quietly empty somebody's group instead of failing loudly.
      [name | _] = @migration.nonsense_tags()
      tag = insert(:tag, name: name)

      Repo.insert!(%NewsletterGroup{name: "Operator's own group", tag_id: tag.id})

      assert %{num_rows: 0} = run_delete([name])
      assert Repo.get(Tag, tag.id)

      assert %{rows: [[1]]} = Repo.query!(@migration.protected_count_sql(), [[name]])
    end
  end
end

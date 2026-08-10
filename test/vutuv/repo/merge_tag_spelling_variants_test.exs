defmodule Vutuv.Repo.MergeTagSpellingVariantsTest do
  @moduledoc """
  Covers the one-time migration `merge_tag_spelling_variants` (issue #1338).

  A fresh test database holds none of the listed tags, so the migration is a
  no-op here and running it would prove nothing about the real merges — that
  check is a run against `vutuv1_dev` (see CLAUDE.md), which reported 279 tags
  absorbed and, on rollback, all 279 put back.

  What this file guards are the properties that would break silently: that the
  list itself is sound, that a tag which is not present is skipped rather than
  fatal (the whole reason other installations can run this), that a tag somebody
  already merged by hand is refused without stopping the rest, and that the
  rollback puts back what the migration did while leaving a human's own merge
  alone.

  It drives `apply_merges/1` and `revert_merges/1`, the migration's own code, so
  the two cannot drift apart.

  `async: false`: the module is loaded from `priv/repo/migrations` with
  `Code.require_file/1`, which is global.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Tags.Merge
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag

  @migration Vutuv.Repo.Migrations.MergeTagSpellingVariants

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      [file] = Path.wildcard("priv/repo/migrations/*_merge_tag_spelling_variants.exs")
      Code.require_file(file)
    end

    :ok
  end

  defp tag(slug, name), do: insert(:tag, name: name, slug: slug)

  describe "the list itself" do
    test "names every group exactly once and never absorbs a tag into itself" do
      merges = @migration.merges()
      keepers = Enum.map(merges, &elem(&1, 0))

      assert keepers == Enum.uniq(keepers)

      for {keeper, absorbed} <- merges do
        assert absorbed != [], "#{keeper} has nothing to absorb"
        assert absorbed == Enum.uniq(absorbed)
        refute keeper in absorbed
      end
    end

    test "builds no chains: a surviving tag is never absorbed elsewhere" do
      # A chain would fail on its second step, since an alternative name may not
      # be absorbed again.
      merges = @migration.merges()
      keepers = MapSet.new(merges, &elem(&1, 0))
      absorbed = merges |> Enum.flat_map(&elem(&1, 1)) |> MapSet.new()

      assert MapSet.disjoint?(keepers, absorbed)
    end

    test "no pair the merge would refuse for punctuation is in it" do
      # The `c` / `c++` / `c#` bucket from #1337 must not be reachable from a
      # list that runs without a human present.
      for {keeper, absorbed} <- @migration.merges(), slug <- absorbed do
        refute Merge.punctuation_only_difference?(keeper, slug),
               "#{keeper} and #{slug} differ only in stripped characters"
      end
    end
  end

  describe "running it" do
    test "an empty catalog is a clean no-op" do
      # The case every other installation and every CI run is in.
      assert @migration.apply_merges(Repo) =~ "0 tags absorbed in 0 groups"
    end

    test "merges a listed group that is present, and moves its rows" do
      {keeper_slug, [absorbed_slug | _]} = hd(@migration.merges())
      keeper = tag(keeper_slug, keeper_slug)
      absorbed = tag(absorbed_slug, absorbed_slug)
      user_tag = insert(:user_tag, user: insert(:activated_user), tag: absorbed)

      report = @migration.apply_merges(Repo)

      assert report =~ "1 tags absorbed in 1 groups"
      assert Repo.get!(Tag, absorbed.id).merged_into_id == keeper.id
      assert Repo.get!(UserTag, user_tag.id).tag_id == keeper.id
    end

    test "a group whose surviving tag is absent is skipped whole" do
      {_keeper_slug, [absorbed_slug | _]} = hd(@migration.merges())
      absorbed = tag(absorbed_slug, absorbed_slug)

      report = @migration.apply_merges(Repo)

      assert report =~ "0 tags absorbed"
      assert is_nil(Repo.get!(Tag, absorbed.id).merged_into_id)
    end

    test "a tag somebody already merged by hand is refused, and the rest still runs" do
      {keeper_slug, absorbed_slugs} =
        Enum.find(@migration.merges(), fn {_k, a} -> length(a) > 1 end)

      [first, second | _] = absorbed_slugs
      keeper = tag(keeper_slug, keeper_slug)
      already = tag(first, first)
      untouched = tag(second, second)

      # Somebody put this one somewhere else already.
      elsewhere = tag("elsewhere-#{System.unique_integer([:positive])}", "Elsewhere")
      {:ok, _} = Merge.merge(already, elsewhere)

      report = @migration.apply_merges(Repo)

      assert report =~ "already_merged"
      assert Repo.get!(Tag, already.id).merged_into_id == elsewhere.id
      assert Repo.get!(Tag, untouched.id).merged_into_id == keeper.id
    end
  end

  describe "rolling it back" do
    test "puts back what the migration merged" do
      {keeper_slug, [absorbed_slug | _]} = hd(@migration.merges())
      keeper = tag(keeper_slug, keeper_slug)
      absorbed = tag(absorbed_slug, absorbed_slug)
      user_tag = insert(:user_tag, user: insert(:activated_user), tag: absorbed)

      @migration.apply_merges(Repo)
      assert @migration.revert_merges(Repo) =~ "1 merges reverted"

      assert is_nil(Repo.get!(Tag, absorbed.id).merged_into_id)
      assert Repo.get!(UserTag, user_tag.id).tag_id == absorbed.id
      assert keeper.id
    end

    test "leaves a merge an admin made by hand alone" do
      # The rollback recognises its own work by there being no admin behind it.
      # Undoing somebody's deliberate merge would be the worst thing this
      # migration could do on the way out.
      {keeper_slug, [absorbed_slug | _]} = hd(@migration.merges())
      keeper = tag(keeper_slug, keeper_slug)
      absorbed = tag(absorbed_slug, absorbed_slug)
      admin = insert(:activated_user)
      {:ok, _} = Merge.merge(absorbed, keeper, actor: admin)

      assert @migration.revert_merges(Repo) =~ "0 merges reverted"
      assert Repo.get!(Tag, absorbed.id).merged_into_id == keeper.id
    end
  end
end

defmodule Vutuv.Repo.FixHashtagPrefixedTagNamesTest do
  @moduledoc """
  Covers the one-time migration `fix_hashtag_prefixed_tag_names`.

  Step 1 (stripping the `#` off a name) is generic, so it is exercised here for
  real. Step 2 names six slugs off vutuv.de's catalog, which a fresh test
  database does not hold — that half is a run against `vutuv1_dev` (see
  CLAUDE.md); what this file guards is that the list is sound, that an absent
  pair is skipped rather than fatal, and that the fold really moves a member's
  rows and really comes back on a rollback.

  It drives `strip_prefixes/1`, `fold_duplicates/1` and `revert_folds/1`, the
  migration's own code, so the two cannot drift apart.

  `async: false`: the module is loaded from `priv/repo/migrations` with
  `Code.require_file/1`, which is global.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Tags.Merge
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag

  @migration Vutuv.Repo.Migrations.FixHashtagPrefixedTagNames

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      [file] = Path.wildcard("priv/repo/migrations/*_fix_hashtag_prefixed_tag_names.exs")
      Code.require_file(file)
    end

    :ok
  end

  defp tag(slug, name), do: insert(:tag, name: name, slug: slug)

  describe "stripping the prefix" do
    test "takes off every leading #, however many and however spaced" do
      rows =
        for {name, expected} <- [
              {"#phoenix", "phoenix"},
              {"##Elixir", "Elixir"},
              {"## Elixir", "Elixir"},
              {"# #Elixir", "Elixir"},
              {"  #Elixir", "Elixir"}
            ] do
          {tag("fixup_#{System.unique_integer([:positive])}", name), expected}
        end

      @migration.strip_prefixes(Repo)

      for {tag, expected} <- rows do
        assert Repo.get!(Tag, tag.id).name == expected
      end
    end

    test "leaves a # that is not leading alone" do
      kept =
        for name <- ["C#", "F#", "fitness#stuff", "Ruby on Rails"] do
          tag("kept_#{System.unique_integer([:positive])}", name)
        end

      @migration.strip_prefixes(Repo)

      for tag <- kept, do: assert(Repo.get!(Tag, tag.id).name == tag.name)
    end

    test "skips a name that is nothing but hashes rather than emptying it" do
      # A blank name is worse than a wrong one: it renders as nothing and no
      # changeset would let it back in.
      hashes = tag("only_hashes_#{System.unique_integer([:positive])}", "## #")

      report = @migration.strip_prefixes(Repo)

      assert report =~ "1 left alone"
      assert Repo.get!(Tag, hashes.id).name == "## #"
    end

    test "reports what it corrected" do
      tag("reported_#{System.unique_integer([:positive])}", "#reported")

      assert @migration.strip_prefixes(Repo) =~ "1 names corrected"
    end
  end

  describe "the fold list itself" do
    test "names every pair exactly once and never folds a tag into itself" do
      folds = @migration.folds()
      slugs = Enum.flat_map(folds, fn {keeper, absorbed} -> [keeper, absorbed] end)

      assert slugs == Enum.uniq(slugs)
      for {keeper, absorbed} <- folds, do: refute(keeper == absorbed)
    end

    test "builds no chains: a surviving tag is never absorbed elsewhere" do
      # A chain would fail on its second step, since an alternative name may not
      # be absorbed again.
      folds = @migration.folds()
      keepers = MapSet.new(folds, &elem(&1, 0))
      absorbed = MapSet.new(folds, &elem(&1, 1))

      assert MapSet.disjoint?(keepers, absorbed)
    end
  end

  describe "folding" do
    test "an empty catalog is a clean no-op" do
      # The case every other installation and every CI run is in.
      assert @migration.fold_duplicates(Repo) =~ "0 duplicates folded"
    end

    test "folds a listed pair that is present, and moves its rows" do
      {keeper_slug, absorbed_slug} = hd(@migration.folds())
      keeper = tag(keeper_slug, keeper_slug)
      absorbed = tag(absorbed_slug, absorbed_slug)
      user_tag = insert(:user_tag, user: insert(:activated_user), tag: absorbed)

      report = @migration.fold_duplicates(Repo)

      assert report =~ "1 duplicates folded"
      assert Repo.get!(Tag, absorbed.id).merged_into_id == keeper.id
      assert Repo.get!(UserTag, user_tag.id).tag_id == keeper.id
    end

    test "a pair whose surviving tag is absent is skipped whole" do
      {_keeper_slug, absorbed_slug} = hd(@migration.folds())
      absorbed = tag(absorbed_slug, absorbed_slug)

      report = @migration.fold_duplicates(Repo)

      assert report =~ "0 duplicates folded"
      assert report =~ "6 listed pairs not present here"
      assert is_nil(Repo.get!(Tag, absorbed.id).merged_into_id)
    end

    test "an alternative name under the absorbed row moves to the survivor" do
      # Otherwise the retired dotted slug would point at an alias, and
      # `Tag.find_by_value/1` follows exactly one hop.
      {keeper_slug, absorbed_slug} = hd(@migration.folds())
      keeper = tag(keeper_slug, keeper_slug)
      absorbed = tag(absorbed_slug, absorbed_slug)
      former = tag("#{absorbed_slug}_former", "#{absorbed_slug}.former")
      {:ok, _} = Merge.merge(former, absorbed)

      @migration.fold_duplicates(Repo)

      assert Repo.get!(Tag, former.id).merged_into_id == keeper.id
      assert Repo.get!(Tag, absorbed.id).merged_into_id == keeper.id
    end

    test "a tag somebody already merged by hand is refused, and the rest still runs" do
      [{first_keeper, first_absorbed}, {second_keeper, second_absorbed} | _] = @migration.folds()

      keeper = tag(first_keeper, first_keeper)
      already = tag(first_absorbed, first_absorbed)
      untouched_keeper = tag(second_keeper, second_keeper)
      untouched = tag(second_absorbed, second_absorbed)

      # Somebody put this one somewhere else already.
      elsewhere = tag("elsewhere_#{System.unique_integer([:positive])}", "Elsewhere")
      {:ok, _} = Merge.merge(already, elsewhere)

      report = @migration.fold_duplicates(Repo)

      assert report =~ "already_merged"
      assert Repo.get!(Tag, already.id).merged_into_id == elsewhere.id
      assert Repo.get!(Tag, untouched.id).merged_into_id == untouched_keeper.id
      assert keeper.id
    end
  end

  describe "rolling back" do
    test "puts back what the migration folded, and leaves the name corrected" do
      {keeper_slug, absorbed_slug} = hd(@migration.folds())
      keeper = tag(keeper_slug, keeper_slug)
      absorbed = tag(absorbed_slug, "##{absorbed_slug}")
      user_tag = insert(:user_tag, user: insert(:activated_user), tag: absorbed)

      @migration.strip_prefixes(Repo)
      @migration.fold_duplicates(Repo)

      assert @migration.revert_folds(Repo) =~ "1 folds reverted"
      assert is_nil(Repo.get!(Tag, absorbed.id).merged_into_id)
      assert Repo.get!(UserTag, user_tag.id).tag_id == absorbed.id
      # The `#` was the bug; a rollback does not put a bug back.
      assert Repo.get!(Tag, absorbed.id).name == absorbed_slug
      assert keeper.id
    end

    test "leaves a merge an admin made by hand alone" do
      # The rollback recognises its own work by there being no admin behind it.
      # Undoing somebody's deliberate merge would be the worst thing this
      # migration could do on the way out.
      {keeper_slug, absorbed_slug} = hd(@migration.folds())
      keeper = tag(keeper_slug, keeper_slug)
      absorbed = tag(absorbed_slug, absorbed_slug)
      admin = insert(:activated_user)
      {:ok, _} = Merge.merge(absorbed, keeper, actor: admin)

      assert @migration.revert_folds(Repo) =~ "0 folds reverted"
      assert Repo.get!(Tag, absorbed.id).merged_into_id == keeper.id
    end
  end
end

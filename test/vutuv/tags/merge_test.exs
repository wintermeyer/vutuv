defmodule Vutuv.Tags.MergeTest do
  use Vutuv.DataCase, async: true

  # Issue #1338: folding one topic's several tags into one page. Absorbing a tag
  # moves rows that people put there deliberately — the tag on their profile,
  # the vouches under it, the posts they filed — so the two things this file
  # cares about most are that nothing is lost on the way over and that the whole
  # act can be taken back.

  alias Vutuv.Newsletters.NewsletterGroup
  alias Vutuv.Posts.PostHashtag
  alias Vutuv.Posts.PostTag
  alias Vutuv.Tags.Merge
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.TagFollow
  alias Vutuv.Tags.UserTag
  alias Vutuv.Tags.UserTagEndorsement

  defp tag(name) do
    insert(:tag, name: name, slug: Vutuv.SlugHelpers.gen_tag_slug_unique(name, Tag, :slug))
  end

  setup do
    %{
      canonical: tag(unique_tag_name("Ruby on Rails")),
      absorbed: tag(unique_tag_name("rubyonrails")),
      admin: insert(:activated_user)
    }
  end

  describe "preview/2" do
    test "counts what would move, per kind", ctx do
      insert(:user_tag, user: insert(:activated_user), tag: ctx.absorbed)
      insert(:user_tag, user: insert(:activated_user), tag: ctx.absorbed)
      Repo.insert!(%PostTag{post_id: insert(:post).id, tag_id: ctx.absorbed.id})
      insert(:tag_follow, user: insert(:activated_user), tag: ctx.absorbed)

      preview = Merge.preview(ctx.absorbed, ctx.canonical)

      assert preview.moved["user_tags"] == 2
      assert preview.moved["post_tags"] == 1
      assert preview.moved["tag_follows"] == 1
      assert preview.dropped == %{}
    end

    test "separates the rows a member already holds on both tags", ctx do
      both = insert(:activated_user)
      insert(:user_tag, user: both, tag: ctx.canonical)
      insert(:user_tag, user: both, tag: ctx.absorbed)
      insert(:user_tag, user: insert(:activated_user), tag: ctx.absorbed)

      preview = Merge.preview(ctx.absorbed, ctx.canonical)

      # One member carries the topic twice, so one of their two rows goes; the
      # other member's row simply moves. An admin has to see that before saying
      # yes, which is the whole point of a preview.
      assert preview.moved["user_tags"] == 1
      assert preview.dropped["user_tags"] == 1
    end

    test "says why a merge is refused, without touching anything", ctx do
      assert {:error, :same_tag} = Merge.preview(ctx.canonical, ctx.canonical)
    end
  end

  describe "preview_many/2 and merge_all/3" do
    test "counts what the sequence really does, not the sum of the pairs", ctx do
      # A topic is spread over several spellings, so tidying it up is a set
      # operation. One member carries two of the absorbed tags and not the
      # surviving one: after the first is absorbed they already hold it, so the
      # second row is dropped. Two independent previews would promise two moves.
      other = tag(unique_tag_name("rails"))
      both = insert(:activated_user)
      insert(:user_tag, user: both, tag: ctx.absorbed)
      insert(:user_tag, user: both, tag: other)

      preview = Merge.preview_many([ctx.absorbed, other], ctx.canonical)

      assert preview.moved["user_tags"] == 1
      assert preview.dropped["user_tags"] == 1

      %{merged: merged, failed: []} =
        Merge.merge_all([ctx.absorbed, other], ctx.canonical, actor: ctx.admin)

      assert length(merged) == 2
      assert Repo.aggregate(from(ut in UserTag, where: ut.user_id == ^both.id), :count) == 1
    end

    test "names the tags it would refuse instead of dropping them quietly", ctx do
      honor =
        tag(unique_tag_name("badge")) |> Ecto.Changeset.change(honor?: true) |> Repo.update!()

      preview = Merge.preview_many([ctx.absorbed, honor], ctx.canonical)

      assert preview.mergeable == [ctx.absorbed]
      assert [{^honor, :honor_tag}] = preview.refused
    end

    test "one refusal does not stop the others", ctx do
      honor =
        tag(unique_tag_name("badge")) |> Ecto.Changeset.change(honor?: true) |> Repo.update!()

      result = Merge.merge_all([ctx.absorbed, honor], ctx.canonical, actor: ctx.admin)

      assert [%{absorbed_tag_id: absorbed_id}] = result.merged
      assert absorbed_id == ctx.absorbed.id
      assert [{_, :honor_tag}] = result.failed
    end

    test "each absorbed tag is its own recorded merge, so each reverts alone", ctx do
      other = tag(unique_tag_name("rails"))
      user_tag = insert(:user_tag, user: insert(:activated_user), tag: other)

      %{merged: [first, second]} =
        Merge.merge_all([ctx.absorbed, other], ctx.canonical, actor: ctx.admin)

      {:ok, _} = Merge.revert(second)

      # Taking one back leaves the other one merged.
      assert Repo.get!(UserTag, user_tag.id).tag_id == other.id
      assert is_nil(Repo.get!(Tag, other.id).merged_into_id)
      assert Repo.get!(Tag, ctx.absorbed.id).merged_into_id == ctx.canonical.id
      assert first.absorbed_tag_id == ctx.absorbed.id
    end
  end

  describe "merge/3" do
    test "moves every kind of row over and files the tag as an alias", ctx do
      holder = insert(:activated_user)
      user_tag = insert(:user_tag, user: holder, tag: ctx.absorbed)
      post = insert(:post)
      post_tag = Repo.insert!(%PostTag{post_id: post.id, tag_id: ctx.absorbed.id})
      hashtag = Repo.insert!(%PostHashtag{post_id: post.id, tag_id: ctx.absorbed.id})
      follow = insert(:tag_follow, user: insert(:activated_user), tag: ctx.absorbed)

      group =
        Repo.insert!(%NewsletterGroup{name: unique_tag_name("Audience"), tag_id: ctx.absorbed.id})

      assert {:ok, merge} = Merge.merge(ctx.absorbed, ctx.canonical, actor: ctx.admin)

      assert Repo.get!(UserTag, user_tag.id).tag_id == ctx.canonical.id
      assert Repo.get!(PostTag, post_tag.id).tag_id == ctx.canonical.id
      assert Repo.get!(PostHashtag, hashtag.id).tag_id == ctx.canonical.id
      assert Repo.get!(TagFollow, follow.id).tag_id == ctx.canonical.id
      assert Repo.get!(NewsletterGroup, group.id).tag_id == ctx.canonical.id

      # The absorbed tag is not deleted: its row is what keeps the old URL alive
      # and what a revert puts back.
      absorbed = Repo.get!(Tag, ctx.absorbed.id)
      assert absorbed.merged_into_id == ctx.canonical.id
      assert absorbed.alias_kind == "former"

      assert merge.canonical_tag_id == ctx.canonical.id
      assert merge.absorbed_tag_id == ctx.absorbed.id
      assert merge.admin_user_id == ctx.admin.id
    end

    test "a member holding both tags keeps one row, and their vouches follow it", ctx do
      both = insert(:activated_user)
      survivor = insert(:user_tag, user: both, tag: ctx.canonical)
      doomed = insert(:user_tag, user: both, tag: ctx.absorbed)

      endorser = insert(:activated_user)
      moved = insert(:user_tag_endorsement, user: endorser, user_tag: doomed)

      # The same person endorsed both spellings, so one of the two endorsements
      # is a duplicate under (endorser, user_tag) and cannot come along.
      shared = insert(:activated_user)
      insert(:user_tag_endorsement, user: shared, user_tag: survivor)
      dropped = insert(:user_tag_endorsement, user: shared, user_tag: doomed)

      assert {:ok, _merge} = Merge.merge(ctx.absorbed, ctx.canonical, actor: ctx.admin)

      refute Repo.get(UserTag, doomed.id)
      assert Repo.get!(UserTag, survivor.id).tag_id == ctx.canonical.id

      # The vouch somebody gave for this person's skill is not collateral.
      assert Repo.get!(UserTagEndorsement, moved.id).user_tag_id == survivor.id
      refute Repo.get(UserTagEndorsement, dropped.id)

      assert Repo.aggregate(from(ut in UserTag, where: ut.user_id == ^both.id), :count) == 1
    end

    test "the counts it reports are the rows it really moved", ctx do
      insert(:user_tag, user: insert(:activated_user), tag: ctx.absorbed)
      Repo.insert!(%PostTag{post_id: insert(:post).id, tag_id: ctx.absorbed.id})

      {:ok, merge} = Merge.merge(ctx.absorbed, ctx.canonical, actor: ctx.admin)

      assert merge.moved_counts["user_tags"] == 1
      assert merge.moved_counts["post_tags"] == 1
    end
  end

  describe "merge/3 refusals" do
    test "a tag cannot absorb itself", ctx do
      assert {:error, :same_tag} = Merge.merge(ctx.canonical, ctx.canonical, actor: ctx.admin)
    end

    test "an honor tag is never merged, in either direction", ctx do
      honor = ctx.absorbed |> Ecto.Changeset.change(honor?: true) |> Repo.update!()

      # An honor tag is an authoritative badge an admin granted, not a spelling
      # somebody chose.
      assert {:error, :honor_tag} = Merge.merge(honor, ctx.canonical, actor: ctx.admin)
      assert {:error, :honor_tag} = Merge.merge(ctx.canonical, honor, actor: ctx.admin)
    end

    test "an alias cannot be absorbed again, nor be absorbed into", ctx do
      {:ok, _} = Merge.merge(ctx.absorbed, ctx.canonical, actor: ctx.admin)
      absorbed = Repo.get!(Tag, ctx.absorbed.id)
      other = tag(unique_tag_name("rails"))

      assert {:error, :already_merged} = Merge.merge(absorbed, other, actor: ctx.admin)
      assert {:error, :target_is_alias} = Merge.merge(other, absorbed, actor: ctx.admin)
    end

    test "a pair marked deliberately distinct stays refused", ctx do
      {:ok, _} = Merge.mark_distinct(ctx.absorbed, ctx.canonical, actor: ctx.admin)

      assert {:error, :marked_distinct} =
               Merge.merge(ctx.absorbed, ctx.canonical, actor: ctx.admin)

      # The mark holds whichever way round the pair is named.
      assert {:error, :marked_distinct} =
               Merge.merge(ctx.canonical, ctx.absorbed, actor: ctx.admin)
    end

    test "names differing only in characters the slugifier strips are refused", ctx do
      # The #1337 bucket: `c`, `c++`, `c#` and `µc` all slugify to `c`, and they
      # are four languages. This is a hard rule, not a matter of judgement, and
      # it applies to a hand-driven merge as much as to a proposed one.
      c = tag("c")
      cpp = tag("c++")
      csharp = tag("c#")

      assert {:error, :punctuation_only_difference} = Merge.merge(cpp, c, actor: ctx.admin)
      assert {:error, :punctuation_only_difference} = Merge.merge(csharp, c, actor: ctx.admin)
      assert {:error, :punctuation_only_difference} = Merge.merge(csharp, cpp, actor: ctx.admin)

      # A pair that differs in letters, not in punctuation, is not caught by it.
      assert {:ok, _} = Merge.merge(ctx.absorbed, ctx.canonical, actor: ctx.admin)
    end

    test "a separator is not punctuation the slugifier strips", ctx do
      # `open source` and `OpenSource` differ only in a space, which the
      # slugifier folds rather than deletes — that pair is the ordinary
      # mechanical variant and must stay mergeable.
      spaced = tag("open source")
      run_together = tag("OpenSource")

      assert {:ok, _} = Merge.merge(run_together, spaced, actor: ctx.admin)
    end
  end

  describe "revert/1" do
    test "puts every moved row back and unfiles the alias", ctx do
      holder = insert(:activated_user)
      user_tag = insert(:user_tag, user: holder, tag: ctx.absorbed)
      post_tag = Repo.insert!(%PostTag{post_id: insert(:post).id, tag_id: ctx.absorbed.id})

      {:ok, merge} = Merge.merge(ctx.absorbed, ctx.canonical, actor: ctx.admin)
      assert {:ok, reverted} = Merge.revert(merge)

      assert Repo.get!(UserTag, user_tag.id).tag_id == ctx.absorbed.id
      assert Repo.get!(PostTag, post_tag.id).tag_id == ctx.absorbed.id
      assert is_nil(Repo.get!(Tag, ctx.absorbed.id).merged_into_id)
      assert is_nil(Repo.get!(Tag, ctx.absorbed.id).alias_kind)
      assert reverted.reverted_at
    end

    test "restores the rows that were dropped as duplicates, with their vouches", ctx do
      both = insert(:activated_user)
      insert(:user_tag, user: both, tag: ctx.canonical)
      doomed = insert(:user_tag, user: both, tag: ctx.absorbed)
      endorsement = insert(:user_tag_endorsement, user: insert(:activated_user), user_tag: doomed)

      {:ok, merge} = Merge.merge(ctx.absorbed, ctx.canonical, actor: ctx.admin)
      refute Repo.get(UserTag, doomed.id)

      assert {:ok, _} = Merge.revert(merge)

      # Same row, same id: a revert restores the state, not something that
      # merely looks like it.
      restored = Repo.get!(UserTag, doomed.id)
      assert restored.tag_id == ctx.absorbed.id
      assert restored.user_id == both.id
      assert Repo.get!(UserTagEndorsement, endorsement.id).user_tag_id == doomed.id
    end

    test "a merge is reverted once", ctx do
      insert(:user_tag, user: insert(:activated_user), tag: ctx.absorbed)
      {:ok, merge} = Merge.merge(ctx.absorbed, ctx.canonical, actor: ctx.admin)
      {:ok, reverted} = Merge.revert(merge)

      assert {:error, :already_reverted} = Merge.revert(reverted)
    end
  end

  describe "mark_distinct/3" do
    test "records the pair whichever way round it is named", ctx do
      {:ok, _} = Merge.mark_distinct(ctx.canonical, ctx.absorbed, actor: ctx.admin)

      assert Merge.distinct?(ctx.absorbed, ctx.canonical)
      assert Merge.distinct?(ctx.canonical, ctx.absorbed)
    end

    test "marking the same pair twice is not an error", ctx do
      {:ok, _} = Merge.mark_distinct(ctx.canonical, ctx.absorbed, actor: ctx.admin)
      assert {:ok, _} = Merge.mark_distinct(ctx.absorbed, ctx.canonical, actor: ctx.admin)
    end
  end
end

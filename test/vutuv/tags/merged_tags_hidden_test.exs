defmodule Vutuv.Tags.MergedTagsHiddenTest do
  use Vutuv.DataCase, async: true

  # Issue #1338 stores an alias as a tag row pointing at its canonical
  # (`merged_into_id`), which buys the retired slug, the stable id and an exact
  # revert — at the price of one rule every tag query has to obey: **a merged
  # tag is never a topic of its own**. A query that forgets it shows the second
  # page for a topic, which is the very bug this issue exists to remove, and it
  # shows it quietly.
  #
  # So this file walks the surfaces one by one rather than trusting a shared
  # scope. Add a surface that lists tags, add it here.

  alias Vutuv.Newsletters
  alias Vutuv.Search
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag

  setup do
    canonical_name = unique_tag_name("Ruby on Rails")
    canonical = insert(:tag, name: canonical_name, slug: slugify(canonical_name))

    absorbed_name = unique_tag_name("rubyonrails")

    absorbed =
      insert(:tag,
        name: absorbed_name,
        slug: slugify(absorbed_name),
        merged_into_id: canonical.id,
        alias_kind: "former"
      )

    %{canonical: canonical, absorbed: absorbed}
  end

  defp slugify(name), do: Vutuv.SlugHelpers.gen_slug_unique(name, Tag, :slug)

  defp with_two_visible_members(tag) do
    for _ <- 1..2, do: insert(:user_tag, user: insert(:activated_user), tag: tag)
    tag
  end

  describe "the tag directory and the search-engine bar" do
    test "the sitemap/indexability set leaves a merged tag out", ctx do
      with_two_visible_members(ctx.canonical)
      with_two_visible_members(ctx.absorbed)

      ids = Tags.indexable_tags_query() |> Repo.all() |> Enum.map(& &1.id)

      assert ctx.canonical.id in ids
      refute ctx.absorbed.id in ids
    end

    test "indexable_tag?/1 is false for a merged tag whatever its numbers", ctx do
      with_two_visible_members(ctx.absorbed)

      refute Tags.indexable_tag?(ctx.absorbed)
    end
  end

  describe "hashtag links in a post body" do
    test "a merged tag's slug links to the canonical page, not to itself", ctx do
      with_two_visible_members(ctx.canonical)

      linkable = Tags.linkable_slugs([ctx.absorbed.slug])

      # The reader should land on the topic, not take a redirect hop: the
      # written slug maps to the canonical one.
      assert linkable == %{ctx.absorbed.slug => ctx.canonical.slug}
    end

    test "a post's #hashtag files it under the canonical tag", ctx do
      assert Tags.tag_ids_for_hashtags([ctx.absorbed.slug]) == [ctx.canonical.id]
    end
  end

  describe "typing a tag" do
    test "the add-tag preview shows the canonical spelling", ctx do
      assert Tags.preview_tag_names(ctx.absorbed.name) == [ctx.canonical.name]
    end
  end

  describe "search" do
    test "searching the merged name finds the canonical tag once", ctx do
      with_two_visible_members(ctx.canonical)

      %{tags: tags} = Search.instant(ctx.absorbed.name)

      assert Enum.map(tags, & &1.id) == [ctx.canonical.id]
    end

    test "searching the canonical name never turns up its aliases", ctx do
      with_two_visible_members(ctx.canonical)

      %{tags: tags} = Search.instant(ctx.canonical.name)

      refute ctx.absorbed.id in Enum.map(tags, & &1.id)
    end
  end

  describe "honor tags" do
    test "a merged tag is not listed among the badges", ctx do
      ctx.absorbed |> Ecto.Changeset.change(honor?: true) |> Repo.update!()

      refute ctx.absorbed.id in Enum.map(Tags.honor_tags(), fn {tag, _count} -> tag.id end)
    end
  end

  describe "the newsletter audience builder" do
    test "targeting a merged name targets the canonical tag", ctx do
      assert Newsletters.find_tag(ctx.absorbed.name).id == ctx.canonical.id
    end
  end
end

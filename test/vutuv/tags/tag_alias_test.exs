defmodule Vutuv.Tags.TagAliasTest do
  use Vutuv.DataCase, async: true

  # Issue #1338: one topic spread over several tags that share no letters
  # (`Ruby on Rails` / `rails` / `ROR` / `rubyonrails`). A tag may now carry
  # alternative names, and an alias is itself a tag row pointing at its
  # canonical through `merged_into_id` — so the alias keeps its own slug (old
  # links survive), its own id (a merge stays revertible) and cannot collide
  # with a real tag, since it lives under the same unique index.
  #
  # What this file guards is the *resolution*: typing any alias must attach the
  # canonical tag rather than mint a new one, which is what stops the sprawl
  # from regrowing.

  import Ecto.Changeset

  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag

  defp canonical_with_alias(kind \\ "alias") do
    name = unique_tag_name("Ruby on Rails")

    canonical =
      insert(:tag, name: name, slug: Vutuv.SlugHelpers.gen_slug_unique(name, Tag, :slug))

    alias_name = unique_tag_name("ROR")

    tag_alias =
      insert(:tag,
        name: alias_name,
        slug: Vutuv.SlugHelpers.gen_slug_unique(alias_name, Tag, :slug),
        merged_into_id: canonical.id,
        alias_kind: kind
      )

    {canonical, tag_alias}
  end

  describe "find_by_value/1" do
    test "an alias name resolves to its canonical tag" do
      {canonical, tag_alias} = canonical_with_alias()

      assert Tag.find_by_value(tag_alias.name).id == canonical.id
    end

    test "an alias slug resolves to its canonical tag" do
      {canonical, tag_alias} = canonical_with_alias()

      assert Tag.find_by_value(tag_alias.slug).id == canonical.id
    end

    test "an alias resolves case-insensitively, like every other tag value" do
      {canonical, tag_alias} = canonical_with_alias()

      assert Tag.find_by_value(String.upcase(tag_alias.name)).id == canonical.id
      assert Tag.find_by_value(String.downcase(tag_alias.name)).id == canonical.id
    end

    test "a canonical tag still resolves to itself" do
      {canonical, _} = canonical_with_alias()

      assert Tag.find_by_value(canonical.name).id == canonical.id
    end
  end

  describe "create_or_link_tag/2" do
    test "typing an alias links the canonical tag instead of minting a duplicate" do
      {canonical, tag_alias} = canonical_with_alias()
      before = Repo.aggregate(Tag, :count)

      changeset =
        %UserTag{}
        |> change(%{})
        |> Tag.create_or_link_tag(%{"value" => tag_alias.name})

      assert get_change(changeset, :tag_id) == canonical.id
      assert Repo.aggregate(Tag, :count) == before
    end
  end

  describe "canonical/1" do
    test "follows the pointer once and stops" do
      {canonical, tag_alias} = canonical_with_alias()

      assert Tag.canonical(tag_alias).id == canonical.id
      assert Tag.canonical(canonical).id == canonical.id
    end
  end

  describe "the alias_kind vocabulary" do
    test "a merged tag must carry a known kind" do
      {canonical, _} = canonical_with_alias()
      name = unique_tag_name("rails")

      changeset =
        Tag.alias_changeset(%Tag{name: name, slug: name}, canonical, "misspelling")

      # Typos are deliberately out of scope (#1338), so there is no
      # `misspelling` kind to file one under.
      refute changeset.valid?
      assert %{alias_kind: [_ | _]} = errors_on(changeset)
    end

    test "alias, abbreviation and former are the whole vocabulary" do
      assert Enum.sort(Tag.alias_kinds()) == ~w(abbreviation alias former)
    end
  end

  describe "aliases_of/1" do
    test "names every tag pointing at this one, in one query" do
      {canonical, tag_alias} = canonical_with_alias()

      assert [found] = Tag.aliases_of(canonical)
      assert found.id == tag_alias.id
    end

    test "an unaliased tag has none" do
      assert Tag.aliases_of(insert(:tag)) == []
    end
  end
end

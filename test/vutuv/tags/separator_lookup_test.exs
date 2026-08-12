defmodule Vutuv.Tags.SeparatorLookupTest do
  @moduledoc """
  One topic, however its separator is typed (issue #1332, want 1).

  `Tag.find_by_value/1` used to key on the exact lowercased name or the exact
  slug, so space against hyphen resolved by accident (the slugifier writes
  hyphens, and the slug is one of the two keys) while **underscore against
  anything did not** — in either direction. That is the shape the older half of
  the catalog carries, so the lookup kept minting a second page for a topic that
  already had one, which is the sprawl #1338's merge pass had just cleaned up.

  Every tag here is minted per test with a unique name, because the tag name is
  a shared lookup key and the slug a unique index (the async rule in
  `.claude/rules/elixir.md`).
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Tags
  alias Vutuv.Tags.Tag

  defp seed(name, slug) do
    n = System.unique_integer([:positive])
    insert(:tag, name: "#{name} #{n}", slug: "#{slug}#{n}")
  end

  describe "find_by_value/1 folds separators" do
    test "a hyphen-slug topic is found however the separator is typed" do
      tag = seed("Probe Framework", "probe-framework-")
      base = tag.name

      for typed <- [
            base,
            String.replace(base, " ", "-"),
            String.replace(base, " ", "_"),
            String.upcase(base),
            String.replace(base, " ", "  "),
            tag.slug,
            String.replace(tag.slug, "-", "_")
          ] do
        assert %Tag{id: found} = Tag.find_by_value(typed), "#{typed} found nothing"
        assert found == tag.id, "#{typed} found another tag"
      end
    end

    test "an underscore-slug topic is found too, which is where it used to fail" do
      tag = seed("Legacy Framework", "legacy_framework_")

      for typed <- [
            tag.name,
            String.replace(tag.name, " ", "-"),
            String.downcase(String.replace(tag.name, " ", "-")),
            tag.slug,
            String.replace(tag.slug, "_", "-")
          ] do
        assert %Tag{id: found} = Tag.find_by_value(typed), "#{typed} found nothing"
        assert found == tag.id, "#{typed} found another tag"
      end
    end

    test "a run of separators collapses to one, but a missing one is not invented" do
      tag = seed("Open Source Software", "open-source-software-")

      assert %Tag{id: id} = Tag.find_by_value(String.replace(tag.name, " ", " - _ "))
      assert id == tag.id

      # `e commerce` against `ecommerce` is a judgement call for a human, so
      # deleting the separator is not part of this: collapse, never delete.
      refute Tag.find_by_value(String.replace(tag.name, " ", ""))
    end

    test "a zero-width character is invisible to a reader and must be to the lookup" do
      tag = seed("Zero Width", "zero-width-")

      assert %Tag{id: id} = Tag.find_by_value(String.replace(tag.name, " ", "​ "))
      assert id == tag.id
    end

    test "a name with nothing to key on matches nothing, rather than grouping" do
      # These normalize to an empty key. Bucketing them would make every one of
      # them the same topic as every other.
      seed("Dash", "dash-")

      for value <- ["-", "--", "_", " ", "."] do
        refute Tag.find_by_value(value), "#{inspect(value)} resolved to a tag"
      end
    end

    test "an alias still resolves to its canonical topic, whatever the spelling" do
      canonical = seed("Canonical Topic", "canonical-topic-")
      n = System.unique_integer([:positive])

      alias_tag =
        insert(:tag,
          name: "Alias Topic #{n}",
          slug: "alias-topic-#{n}",
          merged_into_id: canonical.id
        )

      assert %Tag{id: id} = Tag.find_by_value(String.replace(alias_tag.name, " ", "_"))
      assert id == canonical.id
    end
  end

  describe "canonical_tag_names/1 uses the same key" do
    test "two spellings of one topic count once" do
      tag = seed("Batch Topic", "batch-topic-")
      spaced = tag.name
      underscored = String.replace(tag.name, " ", "_")

      # The batch resolves what a single lookup resolves, or the sign-up
      # three-tag minimum and the composer's cap of five count spellings
      # instead of topics.
      assert Tags.canonical_tag_names([spaced, underscored]) == [tag.name]
    end

    test "an unknown name is kept as typed, and two spellings of it count once" do
      n = System.unique_integer([:positive])
      typed = "Frisch Erfunden #{n}"

      assert [kept] = Tags.canonical_tag_names([typed, String.replace(typed, " ", "-")])
      assert kept == typed
    end
  end
end

defmodule Vutuv.Tags.SeparatorLookupTest do
  @moduledoc """
  One topic, however its separator is typed (issue #1332, want 1).

  `Tag.find_by_value/1` used to key on the exact lowercased name or the exact
  slug, so space against hyphen resolved by accident (the slugifier wrote
  hyphens then, and the slug is one of the two keys) while **underscore against
  anything did not** — in either direction. That was the shape the older half of
  the catalog carried, so the lookup kept minting a second page for a topic that
  already had one, which is the sprawl #1338's merge pass had just cleaned up.

  Since v7.276.2 a live slug can only be `^[a-z0-9_]+$`, so the spellings that
  differ now sit on the **name** (which keeps whatever its first writer typed)
  and on the retired alias rows — and that is where this still has to hold.

  Every tag here is minted per test with a unique name, because the tag name is
  a shared lookup key and the slug a unique index (the async rule in
  `.claude/rules/elixir.md`).
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Tags
  alias Vutuv.Tags.Tag

  # A live tag's slug is an actor name now (`tags_slug_actor_grammar`), so the
  # old spellings live on the **name** and on retired alias rows. That is
  # exactly where the folding still has to work.
  defp seed(name, slug) do
    n = System.unique_integer([:positive])
    insert(:tag, name: "#{name} #{n}", slug: "#{slug}#{n}")
  end

  describe "find_by_value/1 folds separators" do
    test "a topic is found however the separator is typed" do
      tag = seed("Probe Framework", "probe_framework_")
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
      tag = seed("Open Source Software", "open_source_software_")

      assert %Tag{id: id} = Tag.find_by_value(String.replace(tag.name, " ", " - _ "))
      assert id == tag.id

      # `e commerce` against `ecommerce` is a judgement call for a human, so
      # deleting the separator is not part of this: collapse, never delete.
      refute Tag.find_by_value(String.replace(tag.name, " ", ""))
    end

    test "a zero-width character is invisible to a reader and must be to the lookup" do
      tag = seed("Zero Width", "zero_width_")

      assert %Tag{id: id} = Tag.find_by_value(String.replace(tag.name, " ", "​ "))
      assert id == tag.id
    end

    test "a NUL is invisible too, and would otherwise raise on the lookup itself" do
      # The same rule as the zero-width case above with a sharper edge: this
      # one did not miss its topic, it took the query down (#1825). Here the
      # ranking parameter is the raw value, so the key being clean is not
      # enough — `find_by_value/1` drops the byte itself.
      tag = seed("Nul Byte", "nul_byte_")

      assert %Tag{id: id} = Tag.find_by_value(String.replace(tag.name, " ", <<0>> <> " "))
      assert id == tag.id
    end

    test "a name with nothing to key on matches nothing, rather than grouping" do
      # These normalize to an empty key. Bucketing them would make every one of
      # them the same topic as every other.
      seed("Dash", "dash_")

      for value <- ["-", "--", "_", " ", "."] do
        refute Tag.find_by_value(value), "#{inspect(value)} resolved to a tag"
      end
    end

    test "an alias still resolves to its canonical topic, whatever the spelling" do
      canonical = seed("Canonical Topic", "canonical_topic_")
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
      tag = seed("Batch Topic", "batch_topic_")
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

defmodule Vutuv.Tags.TagAliasInputTest do
  use Vutuv.DataCase, async: true

  @moduledoc """
  What a typed tag name really stands for.

  Issue #1338 files an alternative name as a tag row pointing at its topic, so
  `ROR` and `Ruby on Rails` are one subject under two names. The lookup has
  followed that pointer since then — but the two spellings look nothing alike,
  so a member typing both in one go is naming one topic twice without any way
  of seeing it. Everything that takes a batch of typed names therefore
  resolves first and drops the duplicates the resolution creates
  (`Vutuv.Tags.canonical_tag_names/1`), instead of reporting the second
  spelling back as a failed duplicate.
  """

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag

  setup do
    canonical_name = unique_tag_name("Ruby on Rails")
    canonical = insert(:tag, name: canonical_name, slug: slugify(canonical_name))

    %{canonical: canonical, abbreviation: alias_for(canonical, "ROR", "abbreviation")}
  end

  defp alias_for(canonical, base, kind) do
    name = unique_tag_name(base)

    insert(:tag,
      name: name,
      slug: slugify(name),
      merged_into_id: canonical.id,
      alias_kind: kind
    )
  end

  defp slugify(name), do: Vutuv.SlugHelpers.gen_slug_unique(name, Tag, :slug)

  describe "canonical_tag_names/1" do
    test "replaces an alternative name with the topic it points at", ctx do
      assert Tags.canonical_tag_names([ctx.abbreviation.name]) == [ctx.canonical.name]
    end

    test "matches an alternative name case-insensitively, like any tag", ctx do
      assert Tags.canonical_tag_names([String.upcase(ctx.abbreviation.name)]) ==
               [ctx.canonical.name]
    end

    test "names the topic once when both spellings are typed", ctx do
      assert Tags.canonical_tag_names([ctx.abbreviation.name, ctx.canonical.name]) ==
               [ctx.canonical.name]
    end

    test "collapses two alternative names of one topic", ctx do
      former = alias_for(ctx.canonical, "rubyonrails", "former")

      assert Tags.canonical_tag_names([ctx.abbreviation.name, former.name]) ==
               [ctx.canonical.name]
    end

    test "keeps the typed order and the other tags around the duplicate", ctx do
      elixir = unique_tag_name("Elixir")
      go = unique_tag_name("Go")

      assert Tags.canonical_tag_names([elixir, ctx.abbreviation.name, go, ctx.canonical.name]) ==
               [elixir, ctx.canonical.name, go]
    end

    test "passes a name no tag matches through exactly as typed" do
      fresh = unique_tag_name("WebAssembly")

      assert Tags.canonical_tag_names([fresh]) == [fresh]
    end

    test "collapses case variants of a name no tag matches yet" do
      fresh = unique_tag_name("Rust")

      assert Tags.canonical_tag_names([fresh, String.downcase(fresh)]) == [fresh]
    end

    test "answers an empty list without a lookup" do
      assert Tags.canonical_tag_names([]) == []
    end
  end

  describe "the add-tag preview" do
    test "shows the topic once for both of its names", ctx do
      value = "#{ctx.abbreviation.name}, #{ctx.canonical.name}"

      assert Tags.preview_tag_names(value) == [ctx.canonical.name]
    end
  end

  describe "sign-up" do
    setup do
      n = System.unique_integer([:positive])

      %{
        attrs: %{
          "emails" => %{"0" => %{"value" => "alias-input-#{n}@example.com"}},
          "first_name" => "Alias",
          "last_name" => "Input#{n}"
        }
      }
    end

    test "counts one topic once, however many of its names are typed", ctx do
      former = alias_for(ctx.canonical, "rubyonrails", "former")
      tag_list = "#{ctx.abbreviation.name}, #{former.name}, #{ctx.canonical.name}"

      changeset = User.registration_changeset(%User{}, Map.put(ctx.attrs, "tag_list", tag_list))

      # Without the collapse this passes the three-tag minimum and then lands
      # an account holding one tag — the two extra spellings fail the unique
      # index on their way in, silently.
      assert "Please enter at least 3 different tags." in errors_on(changeset).tag_list
    end

    test "materializes an alternative name as the topic itself", ctx do
      tag_list =
        "#{ctx.abbreviation.name}, #{unique_tag_name("Cooking")}, #{unique_tag_name("Origami")}"

      attrs = Map.put(ctx.attrs, "tag_list", tag_list)

      assert {:ok, %User{} = user} = Accounts.register_user(build_conn(), attrs)

      names = Enum.map(user.user_tags, & &1.tag.name)
      assert ctx.canonical.name in names
      refute ctx.abbreviation.name in names
    end
  end

  defp build_conn do
    %Plug.Conn{
      assigns: %{locale: "en"},
      private: %{plug_session: %{}, plug_session_fetch: :done}
    }
    |> Plug.Test.init_test_session(%{})
  end
end

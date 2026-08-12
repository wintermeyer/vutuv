defmodule Vutuv.Tags.TagSlugGrammarTest do
  @moduledoc """
  What a tag slug may contain (issues #1337 and #1332, want 2).

  Two things ride on this. A slug is the tag page's public URL, and the
  slugifier used to delete every symbol that carries meaning in a technology
  name — `c++`, `c#`, `c` and `µc` all slugified to `c`, so three of them lived
  behind a random collision suffix and the readable `/tags/c` belonged to C++.
  And a slug is about to be the name of that tag's fediverse actor (#1330),
  which needs the narrowest local part any server accepts: `^[a-z0-9_]+$`, the
  grammar `Vutuv.Handles` already enforces for member handles.

  The mapping is short and explicit on purpose. Everything it does not name
  keeps behaving as it did.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.SlugHelpers
  alias Vutuv.Tags.Tag

  describe "tagify/1 keeps the characters that distinguish a technology" do
    test "the symbols that carry meaning are transliterated, not deleted" do
      assert SlugHelpers.tagify("c++") == "cpp"
      assert SlugHelpers.tagify("C++") == "cpp"
      assert SlugHelpers.tagify("c#") == "csharp"
      assert SlugHelpers.tagify("F#") == "fsharp"
      assert SlugHelpers.tagify(".net") == "dotnet"
      assert SlugHelpers.tagify("c/c++") == "c_cpp"
      assert SlugHelpers.tagify("c++11") == "cpp11"
      assert SlugHelpers.tagify("ansi c++") == "ansi_cpp"
    end

    test "the four C-family names stay four different slugs" do
      slugs = Enum.map(["c", "c++", "c#", "ansi c++"], &SlugHelpers.tagify/1)
      assert slugs == ["c", "cpp", "csharp", "ansi_cpp"]
      assert length(Enum.uniq(slugs)) == 4
    end

    test "the output is always a valid actor name" do
      for name <- [
            "Machine Learning",
            "Ruby on Rails",
            "Open-Source Software",
            "Prüfer",
            "c/c++",
            "node.js",
            "  spaced  out  ",
            "UPPER_case"
          ] do
        slug = SlugHelpers.tagify(name)
        assert slug =~ ~r/^[a-z0-9_]+$/, "#{name} slugified to #{inspect(slug)}"
      end
    end

    test "a separator run becomes one underscore, and German folds rather than drops" do
      assert SlugHelpers.tagify("Machine Learning") == "machine_learning"
      assert SlugHelpers.tagify("Open-Source  Software") == "open_source_software"
      assert SlugHelpers.tagify("Prüfer") == "pruefer"
      assert SlugHelpers.tagify("Ladesäule") == "ladesaeule"
    end

    test "a name with nothing left answers empty, for the caller to suffix" do
      assert SlugHelpers.tagify("---") == ""
      assert SlugHelpers.tagify("日本語") == ""
    end
  end

  describe "a minted tag" do
    test "gets the readable slug rather than a hash" do
      assert %Tag{slug: "cpp"} = Repo.insert!(Tag.changeset(%Tag{}, %{"value" => "C++"}))
      assert %Tag{slug: "csharp"} = Repo.insert!(Tag.changeset(%Tag{}, %{"value" => "C#"}))
      assert %Tag{slug: "c"} = Repo.insert!(Tag.changeset(%Tag{}, %{"value" => "C"}))
    end

    test "a collision is suffixed with an underscore, not a dot" do
      n = System.unique_integer([:positive])
      insert(:tag, name: "Kollision #{n}", slug: "kollision_#{n}")

      tag = Repo.insert!(Tag.changeset(%Tag{}, %{"value" => "Kollision #{n}"}))

      # A dot would leave the actor namespace (`^[a-z0-9_]+$`) the moment #1330
      # mints an actor for it.
      assert tag.slug =~ ~r/^kollision_#{n}_[a-f0-9]+$/
    end

    test "a name that slugifies to nothing still gets a usable slug" do
      tag = Repo.insert!(Tag.changeset(%Tag{}, %{"value" => "日本語"}))
      assert tag.slug =~ ~r/^[a-z0-9_]+$/
    end
  end

  describe "the other slug users are untouched" do
    test "organizations, jobs and CV sections keep hyphenated slugs" do
      # `slugify_downcase/1` is shared, and a hyphen is the web convention for
      # those URLs. Only the tag needs the handle grammar, because only a tag
      # slug becomes a fediverse actor name.
      assert SlugHelpers.slugify_downcase("Acme Consulting GmbH") == "acme-consulting-gmbh"
    end
  end
end

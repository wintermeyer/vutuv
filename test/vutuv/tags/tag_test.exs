defmodule Vutuv.Tags.TagTest do
  use Vutuv.DataCase, async: true
  alias Vutuv.Tags.Tag

  describe "changeset/2 normalizes the value" do
    import Ecto.Changeset

    test "strips a leading # so the hashtag form stores the bare name" do
      changeset = Tag.changeset(%Tag{}, %{"value" => "#Elixir"})
      assert get_change(changeset, :name) == "Elixir"
      assert get_change(changeset, :slug) == "elixir"
    end

    test "drops a NUL, which Postgres would refuse on the insert" do
      # The write-side guard on its own, so a red run here names the changeset
      # rather than the lookup that precedes it on the minting path (#1825).
      changeset = Tag.changeset(%Tag{}, %{"value" => "Ber" <> <<0>> <> "lin"})
      assert get_change(changeset, :name) == "Berlin"
    end

    test "keeps a trailing # (C# stays C#)" do
      changeset = Tag.changeset(%Tag{}, %{"value" => "C#"})
      assert get_change(changeset, :name) == "C#"
    end

    test "keeps a multi-word name and slugifies it" do
      changeset = Tag.changeset(%Tag{}, %{"value" => "Ruby on Rails"})
      assert get_change(changeset, :name) == "Ruby on Rails"
      # Underscore, not hyphen: a tag slug is also the name of that tag's
      # fediverse actor (#1330), so it lives in the handle grammar (#1337).
      assert get_change(changeset, :slug) == "ruby_on_rails"
    end

    test "collapses internal whitespace runs to a single space" do
      changeset = Tag.changeset(%Tag{}, %{"value" => "Ruby   on  Rails"})
      assert get_change(changeset, :name) == "Ruby on Rails"
    end

    test "strips every leading #, however many and however spaced" do
      for typed <- ["##Elixir", "## Elixir", "# #Elixir", "#  ## # Elixir", "  #Elixir"] do
        assert get_change(Tag.changeset(%Tag{}, %{"value" => typed}), :name) == "Elixir",
               "#{inspect(typed)} did not normalize to \"Elixir\""
      end
    end

    test "a value that is nothing but hashes normalizes to blank and is refused" do
      changeset = Tag.changeset(%Tag{}, %{"value" => "## #"})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "a name may not start with #" do
    # normalize_value/1 strips the hashtag form on every member path, so this
    # backstops the raw name/slug heads — the admin edit form casts :name
    # straight from a text field — and makes the rule fail loudly rather than
    # minting the `#`-prefixed duplicate of a tag that already exists.
    import Ecto.Changeset

    test "the raw name head refuses it" do
      changeset = Tag.changeset(%Tag{}, %{"name" => "#Elixir", "slug" => "elixir"})
      refute changeset.valid?
      assert "must not start with #" in errors_on(changeset).name
    end

    test "the admin edit form refuses it" do
      changeset = Tag.edit_changeset(%Tag{}, %{"name" => "#Elixir", "slug" => "elixir"})
      refute changeset.valid?
      assert "must not start with #" in errors_on(changeset).name
    end

    test "C# and an interior # are untouched" do
      assert Tag.changeset(%Tag{}, %{"name" => "C#", "slug" => "c_sharp"}).valid?
      assert Tag.changeset(%Tag{}, %{"name" => "fitness#stuff", "slug" => "fitness_stuff"}).valid?
    end

    test "a legacy #-named tag stays editable as long as the name is left alone" do
      # validate_change/3 runs only on a *change*, so a row minted before this
      # rule can still have its description edited — the same way the
      # punctuation rule leaves its three legacy rows alone.
      tag = insert(:tag, name: "#legacy_hash_tag", slug: "legacy_hash_tag")

      assert Tag.edit_changeset(tag, %{"description" => "still editable"}).valid?
    end
  end

  describe "related_users/2" do
    test "returns the current user's connections that are endorsed for the tag" do
      # Activated: the tag-page user queries hide unactivated accounts.
      viewer = insert(:user, email_confirmed?: true)
      a_follower = insert(:user, email_confirmed?: true)
      a_followee = insert(:user, email_confirmed?: true)

      # a_follower -> viewer (so a_follower is in viewer.followers)
      insert(:follow, follower: a_follower, followee: viewer)
      # viewer -> a_followee (so a_followee is in viewer.followees)
      insert(:follow, follower: viewer, followee: a_followee)

      tag = insert(:tag)

      for u <- [a_follower, a_followee] do
        user_tag = insert(:user_tag, user: u, tag: tag)
        insert(:user_tag_endorsement, user_tag: user_tag, user: insert(:user))
      end

      # Regression: on Postgres this raised 42P10 (SELECT DISTINCT + ORDER BY
      # count(...)) because followers/followees are has_many :through.
      ids = tag |> Tag.related_users(viewer) |> Enum.map(& &1.id) |> Enum.sort()

      assert ids == Enum.sort([a_follower.id, a_followee.id])
    end

    test "returns [] for an anonymous (nil) current user" do
      assert Tag.related_users(insert(:tag), nil) == []
    end
  end
end

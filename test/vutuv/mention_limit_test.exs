defmodule Vutuv.MentionLimitTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Mentions
  alias Vutuv.Posts.Post
  alias VutuvWeb.ErrorHelpers

  # Every mention notifies the member it names, so a post that advertises
  # something and then lists a column of handles is spam carried by our own
  # notification feed. The cap is what stops it.

  defp handles(count) do
    Enum.map(1..count, fn _ ->
      handle = "member#{System.unique_integer([:positive])}"
      insert(:user, username: handle)
      handle
    end)
  end

  defp body(handles), do: "Buy my thing! " <> Enum.map_join(handles, " ", &("@" <> &1))

  describe "Post.changeset mention cap" do
    test "accepts a post naming exactly the cap" do
      body = body(handles(Mentions.max_post_mentions()))

      assert Post.changeset(%Post{}, %{body: body}).valid?
    end

    test "rejects a post naming one account more" do
      body = body(handles(Mentions.max_post_mentions() + 1))
      changeset = Post.changeset(%Post{}, %{body: body})

      refute changeset.valid?
      assert %{body: messages} = errors_on(changeset)
      assert Enum.any?(messages, &(&1 =~ "at most 5 accounts per post"))
    end

    test "counts accounts, not mentions: naming one member many times is fine" do
      [handle] = handles(1)
      body = "@#{handle} " |> String.duplicate(Mentions.max_post_mentions() + 3) |> String.trim()

      assert Post.changeset(%Post{}, %{body: body}).valid?
    end

    test "organization handles count too (one namespace, both get named)" do
      members = handles(Mentions.max_post_mentions())
      org = "acme#{System.unique_integer([:positive])}"
      insert(:organization, username: org)

      refute Post.changeset(%Post{}, %{body: body(members ++ [org])}).valid?
    end

    test "addresses on another server do not count — nobody here is notified" do
      body = body(handles(Mentions.max_post_mentions())) <> " @bob@geno.social @ann@geno.social"

      assert Post.changeset(%Post{}, %{body: body}).valid?
    end

    test "a handle inside a code span is sample text, not an account" do
      body = body(handles(Mentions.max_post_mentions())) <> " type `@ghost` to mention"

      assert Post.changeset(%Post{}, %{body: body}).valid?
    end

    test "an untouched body is not blocked by the cap on an unrelated edit" do
      post = insert(:post, body: body(handles(Mentions.max_post_mentions() + 4)))

      assert Post.changeset(post, %{license: "cc-by"}).valid?
    end
  end

  describe "the message" do
    test "names the cap and what to do, as a self-contained sentence" do
      changeset = Post.changeset(%Post{}, %{body: body(handles(6))})
      [message] = Enum.filter(errors_on(changeset).body, &(&1 =~ "accounts per post"))

      assert message == "We allow at most 5 accounts per post. Please remove some mentions."
    end

    test "reads in German, which is the language most members see" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")

      german =
        ErrorHelpers.translate_error(
          {"We allow at most %{max} accounts per post. Please remove some mentions.", [max: 5]}
        )

      assert german ==
               "Wir erlauben höchstens 5 Konten pro Beitrag. Bitte entfernen Sie einige Erwähnungen."
    end
  end
end

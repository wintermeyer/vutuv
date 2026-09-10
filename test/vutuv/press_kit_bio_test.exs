defmodule Vutuv.PressKitBioTest do
  @moduledoc """
  The three bios a member writes for their Media Kit (issue #2101).

  What the tests below hold: the three live on one row of their own and are
  written as one thing; the word counts are guidance and the form enforces
  none of them, so eighty words in the short one is stored; the column cap is
  the post body's, because a bio is member Markdown prose exactly as a post is;
  every write asks `Vutuv.PressKit.manageable_by?/2` **per event**, so a viewer
  who is not the owner is refused rather than silently writing somebody else's
  page; and a page has no bios yet but every reader of them can already ask.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Posts.Post
  alias Vutuv.PressKit
  alias Vutuv.PressKit.Bio
  alias Vutuv.Repo

  setup do
    {:ok, user: insert_activated_user()}
  end

  describe "reading" do
    test "a member who has written nothing gets a blank bio, never nil", %{user: user} do
      assert %Bio{short: nil, medium: nil, long: nil} = PressKit.bio(user)
      refute PressKit.any_bio?(PressKit.bio(user))
    end

    test "a page has none, and asking costs no branch at the call site" do
      organization = insert(:organization)

      assert %Bio{short: nil, medium: nil, long: nil} = PressKit.bio(organization)
    end
  end

  describe "writing" do
    test "the three are saved as one row", %{user: user} do
      assert {:ok, bio} =
               PressKit.save_bio(user, user, %{
                 "short" => "Ada builds bridges.",
                 "medium" => "Ada builds bridges, and writes about them.",
                 "long" => "# Ada\n\nAda builds bridges."
               })

      assert bio.short == "Ada builds bridges."
      assert PressKit.any_bio?(bio)
      assert Repo.aggregate(from(b in Bio, where: b.user_id == ^user.id), :count) == 1
    end

    test "saving again updates the same row", %{user: user} do
      {:ok, _bio} = PressKit.save_bio(user, user, %{"short" => "First."})
      {:ok, bio} = PressKit.save_bio(user, user, %{"short" => "Second."})

      assert bio.short == "Second."
      assert Repo.aggregate(from(b in Bio, where: b.user_id == ^user.id), :count) == 1
    end

    test "a blank field is stored as nil, so nothing renders an empty block", %{user: user} do
      {:ok, bio} = PressKit.save_bio(user, user, %{"short" => "   ", "medium" => ""})

      assert bio.short == nil
      assert bio.medium == nil
    end

    test "eighty words in the short bio are stored: the counts are guidance", %{user: user} do
      eighty = Enum.map_join(1..80, " ", &"word#{&1}")

      assert {:ok, bio} = PressKit.save_bio(user, user, %{"short" => eighty})
      assert bio.short == eighty
      assert PressKit.bio_word_target(:short) == 50
    end

    test "past the column cap it is a changeset error, not a Postgres 22001", %{user: user} do
      too_long = String.duplicate("a", PressKit.max_bio_length() + 1)

      assert {:error, changeset} = PressKit.save_bio(user, user, %{"long" => too_long})
      assert %{long: [_message]} = errors_on(changeset)
    end

    test "the cap is the post body's own, asked for rather than copied" do
      assert PressKit.max_bio_length() == Post.max_body_length()
    end

    test "an image is refused at the write, like every other member Markdown column", %{
      user: user
    } do
      assert {:error, changeset} =
               PressKit.save_bio(user, user, %{"short" => "![](https://example.org/x.png)"})

      assert %{short: [_message]} = errors_on(changeset)
      # The rule cannot be left to the renderer: the stored source is what the
      # `.md`, `.json` and export readers get, unrendered.
      assert PressKit.bio(user).short == nil
    end
  end

  describe "who may write one" do
    test "a stranger is refused, and nothing is written", %{user: user} do
      stranger = insert_activated_user()

      assert {:error, :forbidden} = PressKit.save_bio(user, stranger, %{"short" => "Mine now."})
      assert PressKit.bio(user).short == nil
    end

    test "an admin is refused too, the way every other kit write is", %{user: user} do
      admin = insert_activated_user(admin?: true)

      assert {:error, :forbidden} = PressKit.save_bio(user, admin, %{"short" => "Mine now."})
    end

    test "an anonymous viewer is refused", %{user: user} do
      assert {:error, :forbidden} = PressKit.save_bio(user, nil, %{"short" => "Mine now."})
    end
  end

  describe "the word count the editor shows" do
    test "counts the words a reader sees, not the Markdown around them" do
      assert PressKit.bio_word_count("**Ada** builds [bridges](https://example.org).") == 3
    end

    test "an empty bio is zero words" do
      assert PressKit.bio_word_count(nil) == 0
      assert PressKit.bio_word_count("  ") == 0
    end

    test "the long form has no target at all" do
      assert PressKit.bio_word_target(:medium) == 150
      assert PressKit.bio_word_target(:long) == nil
    end
  end
end

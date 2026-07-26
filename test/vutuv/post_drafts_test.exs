defmodule Vutuv.PostDraftsTest do
  @moduledoc """
  Composer drafts (issue #1148 follow-up): the store behind "a reload no longer
  empties the composer". The context layer only — the composer's own restore
  behaviour lives in `VutuvWeb.ComposerDraftTest`.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostDraft
  alias Vutuv.Posts.PostImage

  defp user(attrs \\ []), do: insert(:activated_user, attrs)

  defp attrs(overrides \\ %{}) do
    Map.merge(%{"body" => "half a thought", "tags" => "", "mode" => "text"}, overrides)
  end

  describe "save_draft/3 and get_draft/2" do
    test "a new-post draft round trips" do
      author = user()

      :ok = Posts.save_draft(author, nil, attrs())

      assert %PostDraft{body: "half a thought", mode: "text"} = Posts.get_draft(author, nil)
    end

    test "saving again replaces the draft instead of collecting a second one" do
      author = user()

      :ok = Posts.save_draft(author, nil, attrs())
      :ok = Posts.save_draft(author, nil, attrs(%{"body" => "a fuller thought"}))

      assert %PostDraft{body: "a fuller thought"} = Posts.get_draft(author, nil)
      assert Repo.aggregate(from(d in PostDraft, where: d.user_id == ^author.id), :count) == 1
    end

    test "each composer context keeps its own draft" do
      author = user()
      parent = insert(:post)
      other_parent = insert(:post)

      :ok = Posts.save_draft(author, nil, attrs(%{"body" => "a new post"}))
      :ok = Posts.save_draft(author, parent, attrs(%{"body" => "an answer"}))
      :ok = Posts.save_draft(author, other_parent, attrs(%{"body" => "another answer"}))

      assert %PostDraft{body: "a new post"} = Posts.get_draft(author, nil)
      assert %PostDraft{body: "an answer"} = Posts.get_draft(author, parent)
      assert %PostDraft{body: "another answer"} = Posts.get_draft(author, other_parent)
    end

    test "one member's draft is invisible to another" do
      author = user()
      stranger = user()

      :ok = Posts.save_draft(author, nil, attrs())

      assert Posts.get_draft(stranger, nil) == nil
    end

    test "an emptied composer clears the draft rather than storing a blank one" do
      author = user()

      :ok = Posts.save_draft(author, nil, attrs())
      :ok = Posts.save_draft(author, nil, attrs(%{"body" => ""}))

      assert Posts.get_draft(author, nil) == nil
      assert Repo.aggregate(from(d in PostDraft, where: d.user_id == ^author.id), :count) == 0
    end

    test "tags alone are worth keeping" do
      author = user()

      :ok = Posts.save_draft(author, nil, attrs(%{"body" => "", "tags" => "elixir"}))

      assert %PostDraft{tags: "elixir"} = Posts.get_draft(author, nil)
    end

    test "photos alone are worth keeping" do
      author = user()
      image = insert(:post_image, user: author, post: nil)

      :ok = Posts.save_draft(author, nil, attrs(%{"body" => "", "image_ids" => [image.id]}))

      assert %PostDraft{image_ids: [id]} = Posts.get_draft(author, nil)
      assert id == image.id
    end

    test "an autosave the post itself would refuse is skipped, not raised" do
      author = user()
      too_long = String.duplicate("x", Post.max_body_length() + 1)

      assert :ok = Posts.save_draft(author, nil, attrs(%{"body" => too_long}))
      assert Posts.get_draft(author, nil) == nil
    end
  end

  describe "delete_draft/2" do
    test "drops only the named context" do
      author = user()
      parent = insert(:post)

      :ok = Posts.save_draft(author, nil, attrs())
      :ok = Posts.save_draft(author, parent, attrs())

      :ok = Posts.delete_draft(author, nil)

      assert Posts.get_draft(author, nil) == nil
      assert %PostDraft{} = Posts.get_draft(author, parent)
    end
  end

  describe "sweep_drafts/1" do
    test "removes drafts nobody has touched in a month, keeps the fresh ones" do
      author = user()
      parent = insert(:post)

      :ok = Posts.save_draft(author, nil, attrs())
      :ok = Posts.save_draft(author, parent, attrs())

      stale = Posts.get_draft(author, nil)
      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -40 * 86_400)
      Repo.update_all(from(d in PostDraft, where: d.id == ^stale.id), set: [updated_at: long_ago])

      assert Posts.sweep_drafts() == 1
      assert Posts.get_draft(author, nil) == nil
      assert %PostDraft{} = Posts.get_draft(author, parent)
    end
  end

  describe "sweep_pending_images/1 and drafts" do
    test "a photo a draft still names survives the sweep" do
      author = user()
      drafted = insert(:post_image, user: author, post: nil)
      abandoned = insert(:post_image, user: author, post: nil)

      :ok = Posts.save_draft(author, nil, attrs(%{"image_ids" => [drafted.id]}))
      backdate_images!([drafted.id, abandoned.id])

      assert Posts.sweep_pending_images() == 1

      assert Repo.get(PostImage, drafted.id)
      refute Repo.get(PostImage, abandoned.id)
    end

    test "once the draft is gone the photo is sweepable again" do
      author = user()
      image = insert(:post_image, user: author, post: nil)

      :ok = Posts.save_draft(author, nil, attrs(%{"image_ids" => [image.id]}))
      :ok = Posts.delete_draft(author, nil)
      backdate_images!([image.id])

      assert Posts.sweep_pending_images() == 1
      refute Repo.get(PostImage, image.id)
    end
  end

  # The sweep only looks at images older than its cutoff; age them past it.
  defp backdate_images!(ids) do
    long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3 * 86_400)
    Repo.update_all(from(i in PostImage, where: i.id in ^ids), set: [inserted_at: long_ago])
  end
end

defmodule Vutuv.AccountDeletionTest do
  @moduledoc """
  Deleting a user must be clean and complete: every row that belongs to the
  account goes (DB cascade), the records that deliberately outlive their author
  survive in a degraded form (replies to the account's posts, the sent
  messages), and the on-disk files the cascade cannot touch (post images,
  avatar, cover) are removed too.

  This pins the gap `Vutuv.Accounts.delete_user/1` closes: the image files were
  orphaned on disk because the cascade only drops the rows that name them, so
  the chokepoint collects their paths before the delete and removes them after.
  """
  # Not async: sets the global :uploads_dir_prefix and plants files on disk.
  use Vutuv.DataCase, async: false

  import Ecto.Query
  import Vutuv.PostsHelpers, only: [create_post!: 2]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.{Email, User, UsernameChange}
  alias Vutuv.Chat.{Conversation, Message}
  alias Vutuv.Moderation
  alias Vutuv.Posts.{Post, PostDenial, PostImage, PostReply}
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Social.{Connection, Follow}
  alias Vutuv.Tags.{UserTag, UserTagEndorsement}
  alias Vutuv.Uploads
  alias Vutuv.Uploads.Originals

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_del_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:vutuv, :uploads_dir_prefix, prev),
        else: Application.delete_env(:vutuv, :uploads_dir_prefix)
    end)

    :ok
  end

  # Plant a real file in `storage_dir` (served tree) and its private original,
  # so the test can assert both are removed.
  defp plant_files(storage_dir) do
    served = Uploads.disk_dir(storage_dir)
    original = Originals.dir(storage_dir)

    for dir <- [served, original] do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "marker"), "x")
    end

    {served, original}
  end

  defp count(queryable), do: Repo.aggregate(queryable, :count)

  test "delete_user wipes the account, all its rows, and its on-disk files" do
    user = insert(:activated_user, avatar: "a.jpg", cover_photo: "c.jpg")
    other = insert(:activated_user)
    third = insert(:activated_user)
    fourth = insert(:activated_user)

    # --- Profile data (every direct user-owned table) ---
    insert(:email, user: user)
    insert(:username_change, user: user)

    # A moderation case against the account, with an on-disk evidence
    # screenshot that must be purged with everything else.
    evidence_reporter = insert(:activated_user)

    {:ok, evidence_case} =
      Moderation.report_content(evidence_reporter, user, %{"category" => "spam"})

    evidence_file = Moderation.EvidenceScreenshot.path("#{evidence_case.id}.webp")
    File.mkdir_p!(Path.dirname(evidence_file))
    File.write!(evidence_file, "evidence")
    on_exit(fn -> File.rm(evidence_file) end)

    Repo.update!(
      Ecto.Changeset.change(evidence_case, evidence_screenshot: "#{evidence_case.id}.webp")
    )

    insert(:work_experience, user: user)
    insert(:address, user: user)
    insert(:phone_number, user: user)
    url = insert(:url, user: user)
    insert(:social_media_account, user: user)
    insert(:login_pin, user: user)
    insert(:search_term, user: user)

    # --- Tags + endorsements (given by and received by the account) ---
    tag = insert(:tag)
    user_tag = insert(:user_tag, user: user, tag: tag)
    insert(:user_tag_endorsement, user: other, user_tag: user_tag)
    other_tag = insert(:user_tag, user: other, tag: tag)
    given_endorsement = insert(:user_tag_endorsement, user: user, user_tag: other_tag)

    # --- Social graph ---
    follow!(third, user)
    connect!(user, other)
    {:ok, _} = Social.request_connection(user, fourth)
    {:ok, _} = Social.request_connection(third, user)

    # --- A post that hides itself from one person (a per-user denial), an
    #     attached image, and a pending (unattached) image. ---
    post = create_post!(user, %{body: "private", denials: [%{"denied_user_id" => other.id}]})
    attached = insert(:post_image, user: user, post: post)
    pending = insert(:post_image, user: user)

    # --- A reply by someone else to the account's post: it must outlive the
    #     account, with its parent links nilified. ---
    reply_post = create_post!(other, %{body: "re: private"})
    reply = insert(:post_reply, post: reply_post, parent_post: post, parent_author: user)

    # --- A conversation with messages the account sent. ---
    conversation = insert_conversation_between(user, other)
    message = insert(:message, conversation: conversation, sender: user)

    # --- Plant on-disk files for the avatar, cover and both images. ---
    {avatar_served, avatar_orig} = plant_files("avatars/#{user.id}")
    {cover_served, cover_orig} = plant_files("covers/#{user.id}")
    {attached_served, attached_orig} = plant_files("post_images/#{attached.token}")
    {pending_served, pending_orig} = plant_files("post_images/#{pending.token}")
    {screenshot_served, screenshot_orig} = plant_files("screenshots/#{url.id}")

    # A follower with the feed open should hear that the account's post is gone
    # (the follow edge is captured before the delete, since it cascades away).
    Vutuv.Activity.subscribe(third.id)
    post_id = post.id

    # === Delete ===
    assert {:ok, _} = Accounts.delete_user(user)

    assert_receive {:post_deleted, %{post_id: ^post_id}}

    # --- The account is gone; the other parties survive. ---
    refute Repo.get(User, user.id)
    assert Repo.get(User, other.id)
    assert Repo.get(User, third.id)
    assert Repo.get(User, fourth.id)

    # --- No orphaned rows anywhere the account reached. ---
    assert count(from(e in Email, where: e.user_id == ^user.id)) == 0
    assert count(from(s in UsernameChange, where: s.user_id == ^user.id)) == 0

    assert count(from(f in Follow, where: f.follower_id == ^user.id or f.followee_id == ^user.id)) ==
             0

    assert count(from(c in Connection, where: c.user_a_id == ^user.id or c.user_b_id == ^user.id)) ==
             0

    assert count(from(p in Post, where: p.user_id == ^user.id)) == 0
    assert count(from(i in PostImage, where: i.user_id == ^user.id)) == 0
    assert count(from(d in PostDenial, where: d.post_id == ^post.id)) == 0
    assert count(from(t in UserTag, where: t.user_id == ^user.id)) == 0
    assert count(from(e in UserTagEndorsement, where: e.user_id == ^user.id)) == 0
    refute Repo.get(UserTagEndorsement, given_endorsement.id)
    refute Repo.get(Conversation, conversation.id)
    refute Repo.get(Message, message.id)

    # --- The other party's own data is untouched. ---
    assert Repo.get(UserTag, other_tag.id)

    # --- The reply outlives the deleted parent and author, degraded to nil. ---
    assert Repo.get(Post, reply_post.id)
    reply = Repo.get!(PostReply, reply.id)
    assert reply.parent_post_id == nil
    assert reply.parent_author_id == nil

    # --- Every planted file is gone (served + private original). ---
    for dir <- [
          avatar_served,
          avatar_orig,
          cover_served,
          cover_orig,
          attached_served,
          attached_orig,
          pending_served,
          pending_orig,
          screenshot_served,
          screenshot_orig
        ] do
      refute File.exists?(dir), "expected #{dir} to be removed"
    end

    # --- The moderation evidence screenshot is purged with the account. ---
    refute File.exists?(evidence_file)
  end
end

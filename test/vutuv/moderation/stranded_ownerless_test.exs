defmodule Vutuv.Moderation.StrandedOwnerlessTest do
  @moduledoc """
  `ImageSubjects.stranded_pending/0` for the two kinds nobody here uploaded
  (issue #1163): a picture on a cached remote post, and a remote account's
  avatar. Both re-enqueue with a `nil` owner, and neither is stranded before
  its bytes have actually been fetched.

  These two had no test at all, which mattered once the five flat stranded
  queries collapsed into one config-driven function: the ownerless branch is
  the only one that selects a literal `nil` for the owner, and the
  `require_file` guard is the only `where` that is conditional.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Moderation.ImageSubjects

  defp stranded_of(kind) do
    ImageSubjects.stranded_pending()
    |> Enum.filter(fn {k, _id, _owner, _fp} -> k == kind end)
  end

  describe "remote_avatar" do
    test "a pending avatar with bytes on disk is stranded, owned by nobody" do
      account = remote_account(avatar: "abc.jpg", avatar_moderation: "pending")

      assert [{"remote_avatar", id, owner, fingerprint}] = stranded_of("remote_avatar")
      assert id == account.id
      assert owner == nil
      assert fingerprint == "abc.jpg"
    end

    test "a pending avatar whose bytes never arrived is not stranded" do
      # The row is written from the actor document; the picture is fetched
      # afterwards. Between the two there is nothing on disk to judge, so
      # `pending` here is not drift.
      remote_account(avatar: nil, avatar_moderation: "pending")

      assert stranded_of("remote_avatar") == []
    end

    test "an avatar already judged is not stranded" do
      remote_account(avatar: "abc.jpg", avatar_moderation: "approved")

      assert stranded_of("remote_avatar") == []
    end
  end

  describe "remote_post_image" do
    test "a pending picture with bytes on disk is stranded, owned by nobody" do
      post = remote_account() |> cached_post()

      image =
        Repo.insert!(%RemoteImage{
          remote_post_id: post.id,
          source_uri: "https://social.example/media/1.jpg",
          file: "1.jpg",
          moderation: "pending"
        })

      assert [{"remote_post_image", id, owner, fingerprint}] = stranded_of("remote_post_image")
      assert id == image.id
      assert owner == nil
      assert fingerprint == "1.jpg"
    end

    test "a picture whose bytes never arrived is not stranded" do
      post = remote_account() |> cached_post()

      Repo.insert!(%RemoteImage{
        remote_post_id: post.id,
        source_uri: "https://social.example/media/1.jpg",
        file: nil,
        moderation: "pending"
      })

      assert stranded_of("remote_post_image") == []
    end
  end
end

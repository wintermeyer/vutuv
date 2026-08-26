defmodule Vutuv.FediverseImageHoldTest do
  @moduledoc """
  A post whose picture the AI scan has not judged yet waits before it federates
  (issue #1070), so the picture goes out with it instead of never going out at
  all.

  The two things worth pinning down: the hold is released the moment the scan
  settles (which is the normal case, a few seconds), and a slow verdict costs
  the post nothing but time — a delivery that comes due while the scan is still
  out goes back in the queue rather than travelling without the picture (issue
  #1720; until then this mark was a ceiling, and the post left without it).

  async: false — flips the global `:fediverse_image_hold_seconds`.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.PostDelivery
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Posts
  alias Vutuv.Posts.PostDenial
  alias Vutuv.Posts.PostImage
  alias Vutuv.ReviewCover

  setup do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)

    {:ok, _follower} =
      Fediverse.add_follower(user, %{
        actor_uri: "https://follower.example/users/f",
        inbox_uri: "https://follower.example/inbox"
      })

    {:ok, user: user}
  end

  defp pending_image!(post), do: insert(:post_image, post: post, moderation: "pending")

  defp release!(%PostImage{} = image),
    do: image |> Ecto.Changeset.change(moderation: "approved") |> Repo.update!()

  describe "a post with a picture still in limbo" do
    test "is held back, carrying the marker that re-renders it later", %{user: user} do
      post = insert(:post, user: user, body: "Mit Bild")
      pending_image!(post)

      assert :ok == Fediverse.federate_new_post(post)

      assert [%Delivery{} = delivery] = Repo.all(Delivery)
      assert delivery.rebuild_from == "post_create:#{post.id}"
      # Not due yet: the scan gets its chance first.
      assert DateTime.compare(delivery.next_attempt_at, DateTime.utc_now()) == :gt
      # Still a complete activity, so a release that knows nothing of the marker
      # delivers this rather than choking on a half-built row.
      assert delivery.activity_json =~ ~s("type":"Create")
    end

    test "goes out at once once the scan settles", %{user: user} do
      post = insert(:post, user: user, body: "Mit Bild")
      image = pending_image!(post)
      assert :ok == Fediverse.federate_new_post(post)

      release!(image)
      assert :ok == Fediverse.images_settled(post.id)

      # Still the one Create, pulled forward and still carrying its marker: it
      # re-renders with the picture at send time. A second row here would mean
      # the late-scan Update below had delivered the same post twice.
      assert [%Delivery{next_attempt_at: due, rebuild_from: marker}] = Repo.all(Delivery)
      assert marker == "post_create:#{post.id}"
      assert DateTime.compare(due, DateTime.utc_now()) != :gt
    end

    test "keeps waiting while a second picture is still pending", %{user: user} do
      post = insert(:post, user: user, body: "Zwei Bilder")
      first = pending_image!(post)
      _second = pending_image!(post)
      assert :ok == Fediverse.federate_new_post(post)

      release!(first)
      :ok = Fediverse.images_settled(post.id)

      # The post waits for the last picture, not the first.
      assert [%Delivery{next_attempt_at: due}] = Repo.all(Delivery)
      assert DateTime.compare(due, DateTime.utc_now()) == :gt
    end
  end

  describe "a post with nothing pending" do
    test "federates immediately, with no marker", %{user: user} do
      post = insert(:post, user: user, body: "Nur Text")

      assert :ok == Fediverse.federate_new_post(post)

      assert [%Delivery{rebuild_from: nil, next_attempt_at: due}] = Repo.all(Delivery)
      assert DateTime.compare(due, DateTime.utc_now()) != :gt
    end

    test "counts an already released picture as nothing pending", %{user: user} do
      post = insert(:post, user: user, body: "Mit fertigem Bild")
      insert(:post_image, post: post, moderation: "approved")

      assert :ok == Fediverse.federate_new_post(post)
      assert [%Delivery{rebuild_from: nil}] = Repo.all(Delivery)
    end
  end

  describe "awaiting_image_release?/1" do
    test "is true only while a picture is unjudged", %{user: user} do
      post = insert(:post, user: user, body: "Mit Bild")
      image = pending_image!(post)

      assert Posts.awaiting_image_release?(post.id)

      release!(image)
      refute Posts.awaiting_image_release?(post.id)
    end

    test "a rejected picture counts as settled, not as pending", %{user: user} do
      post = insert(:post, user: user, body: "Mit Bild")
      image = pending_image!(post)

      # A rejection deletes the row, which is what the real path does; either way
      # the post is no longer waiting on anybody.
      Repo.delete!(image)
      refute Posts.awaiting_image_release?(post.id)
    end

    test "an unknown post is not waiting for anything" do
      refute Posts.awaiting_image_release?(Vutuv.UUIDv7.generate())
    end

    test "released?/1 is the single source of the verdict" do
      # Guards against the hold and the renderer drifting apart: both ask this.
      assert ImageScans.released?("approved")
      refute ImageScans.released?("pending")
    end
  end

  describe "a scan that settles after the post already federated (issue #1585)" do
    test "sends the picture after it with an Update", %{user: user} do
      post = insert(:post, user: user, body: "Mit Bild")
      image = pending_image!(post)
      assert :ok == Fediverse.federate_new_post(post)

      # The hold ran out and the Create went to the follower: the queue row is
      # deleted on success, and the PostDelivery record of where it went stays.
      # That is exactly the state issue #1585 was reported from.
      Repo.delete_all(Delivery)
      assert Repo.aggregate(PostDelivery, :count) > 0

      release!(image)
      assert :ok == Fediverse.images_settled(post.id)

      assert [%Delivery{} = delivery] = Repo.all(Delivery)
      assert delivery.activity_json =~ ~s("type":"Update")
      # The whole point: the follower that already has the text now gets the
      # picture. Without the Update it never would - nothing else revisits a
      # post whose scan came back late.
      assert delivery.activity_json =~ PostImage.url(image, "large")
    end

    test "carries a book review's cover, which never federated before", %{user: user} do
      # A cover is fetched in a task AFTER the post commits, so `cover_status`
      # is still "pending" here and `awaiting_image_release?/1` never holds the
      # post — the Create leaves without it and nothing used to follow.
      post = insert(:post, user: user, body: "Ein Buch")
      review = insert(:post_review, post: post, cover_status: "pending")

      assert :ok == Fediverse.federate_new_post(post)
      assert [%Delivery{rebuild_from: nil}] = Repo.all(Delivery)
      Repo.delete_all(Delivery)

      review
      |> Ecto.Changeset.change(
        cover_status: "ready",
        cover: "cover.avif",
        cover_moderation: "approved"
      )
      |> Repo.update!()

      assert :ok == Fediverse.images_settled(post.id)

      assert [%Delivery{} = delivery] = Repo.all(Delivery)
      assert delivery.activity_json =~ ~s("type":"Update")
      assert delivery.activity_json =~ ReviewCover.url(Repo.reload!(review))
    end

    test "stays silent for a post that never federated" do
      # No followers, so `federate_new_post/1` enqueued nothing and recorded
      # nothing. An Update here would be addressed at nobody.
      lonely = insert(:activated_user, fediverse_followers?: true)
      {:ok, _actor} = Fediverse.ensure_actor(lonely)
      post = insert(:post, user: lonely, body: "Mit Bild")
      image = pending_image!(post)

      assert :skip == Fediverse.federate_new_post(post)

      release!(image)
      assert :ok == Fediverse.images_settled(post.id)

      assert Repo.all(Delivery) == []
    end
  end

  describe "the hold ceiling" do
    test "is what the post waits, and it is configurable", %{user: user} do
      Application.put_env(:vutuv, :fediverse_image_hold_seconds, 5)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_image_hold_seconds) end)

      assert Fediverse.image_hold_seconds() == 5

      post = insert(:post, user: user, body: "Mit Bild")
      pending_image!(post)
      before = DateTime.utc_now(:second)

      assert :ok == Fediverse.federate_new_post(post)

      after_the_call = DateTime.utc_now(:second)

      assert [%Delivery{next_attempt_at: due}] = Repo.all(Delivery)
      # The code stamps `DateTime.utc_now(:second) + hold` somewhere between
      # the two clock reads above, so the due time is bracketed by them. A
      # single-sided `diff(due, before) <= 5` flakes whenever the wall clock
      # crosses a second boundary inside the call (read 6 on a loaded CI
      # runner, 2026-07-30) — and the bracket is also the stronger claim: the
      # wait IS the configured hold, not merely at most it.
      assert DateTime.diff(due, before) >= 5
      assert DateTime.diff(due, after_the_call) <= 5
    end

    test "defaults to 90 seconds" do
      assert Fediverse.image_hold_seconds() == 90
    end
  end

  describe "a held delivery that comes due while the scan is still out" do
    # Issue #1720: this used to be where a slow verdict lost the picture — the
    # ceiling ran out, the post went to the followers with no attachment, and
    # only an "edited" Update could bring the picture afterwards. It goes back
    # in the queue instead now, for as long as it takes.
    test "goes back in the queue rather than out without the picture", %{user: user} do
      Application.put_env(:vutuv, :fediverse_image_hold_seconds, 5)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_image_hold_seconds) end)

      post = insert(:post, user: user, body: "Mit Bild")
      pending_image!(post)
      assert :ok == Fediverse.federate_new_post(post)

      due_now!()
      before = DateTime.utc_now(:second)
      assert Fediverse.deliver_due() == 1
      after_the_call = DateTime.utc_now(:second)

      # The row surviving the drain IS the proof that nothing went out: a
      # delivered activity deletes its row.
      assert [%Delivery{} = reparked] = Repo.all(Delivery)
      # A wait is not a failure: eight of these would retire the row at the
      # attempt cap and lose the post for good.
      assert reparked.attempts == 0
      assert reparked.last_error == nil
      # And it is not due any more — a row that stayed due would be picked up
      # by every drain and hold the front of the queue (the #1316 shape).
      assert DateTime.diff(reparked.next_attempt_at, before) >= 5
      assert DateTime.diff(reparked.next_attempt_at, after_the_call) <= 5
    end

    # A post whose audience closed while it waited must never travel. The trap:
    # two boolean steps in one `with` chain both fail with `true`, so an
    # else-clause reading `true -> :hold` catches the closed audience as well
    # and keeps a delivery alive that should have been dropped. Calibrated —
    # with the picture question inside that chain, the row is still there.
    test "drops a delivery whose post was closed during the wait", %{user: user} do
      post = insert(:post, user: user, body: "Mit Bild")
      image = pending_image!(post)
      assert :ok == Fediverse.federate_new_post(post)

      # A denial is what makes a post `Posts.restricted?/1`.
      Repo.insert!(%PostDenial{post_id: post.id, wildcard: "everyone"})
      release!(image)
      due_now!()

      assert Fediverse.deliver_due() == 1
      assert Repo.all(Delivery) == []
    end

    test "travels with the picture once the verdict finally lands", %{user: user} do
      post = insert(:post, user: user, body: "Mit Bild")
      image = pending_image!(post)
      assert :ok == Fediverse.federate_new_post(post)

      due_now!()
      assert Fediverse.deliver_due() == 1
      assert [%Delivery{}] = Repo.all(Delivery)

      release!(image)
      assert :ok == Fediverse.images_settled(post.id)

      # Due again on the spot, unspent and still carrying its marker: the
      # release is what ends the wait, the re-park only kept the row alive
      # until it came, and the marker is what re-renders the Note WITH the
      # picture at send time.
      assert [%Delivery{next_attempt_at: due, attempts: 0, rebuild_from: marker}] =
               Repo.all(Delivery)

      assert marker == "post_create:#{post.id}"
      assert DateTime.compare(due, DateTime.utc_now()) != :gt
    end
  end

  # Backdates the queued row so the next drain picks it up, the way the clock
  # would have by itself.
  defp due_now! do
    Repo.update_all(Delivery, set: [next_attempt_at: DateTime.add(DateTime.utc_now(:second), -1)])
  end
end

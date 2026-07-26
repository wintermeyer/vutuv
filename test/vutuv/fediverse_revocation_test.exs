defmodule Vutuv.FediverseRevocationTest do
  @moduledoc """
  Taking something back off the other servers (issue #1102).

  Before this, only the owner's own delete button federated a `Delete`: a report
  that froze a post, an admin removal and the strike ladder all hid the content
  here and told the network nothing, and a reported reply from another network
  was deleted from our cache while its origin never learned anybody objected.

  async: false — the HTTP stub and the report rate limit both live outside the
  SQL sandbox (the app env and the shared `Vutuv.RateLimiter` ETS table).
  """
  use Vutuv.DataCase, async: false

  import Ecto.Query
  import Vutuv.PostsHelpers

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.DeliveryFailure
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.NoteEvent
  alias Vutuv.Fediverse.PostDelivery
  alias Vutuv.Moderation
  alias VutuvWeb.Fediverse.Docs

  @public "https://www.w3.org/ns/activitystreams#Public"
  @remote_actor "https://social.example/users/alice"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp federating(attrs \\ []) do
    user = insert(:activated_user, Keyword.merge([fediverse_followers?: true], attrs))
    {:ok, _actor} = Fediverse.ensure_actor(user)
    user
  end

  defp follower_on(user, host) do
    {:ok, follower} =
      Fediverse.add_follower(user, %{
        actor_uri: "https://#{host}/users/x",
        inbox_uri: "https://#{host}/inbox"
      })

    follower
  end

  # A post that really went out: enqueued, recorded, and the queue cleared again
  # so each test only sees what its own takedown produced.
  defp published_post(user, body \\ "Federated far and wide.") do
    post = create_post!(user, %{"body" => body})
    Repo.delete_all(Delivery)
    post
  end

  defp deliveries, do: Repo.all(from(d in Delivery, order_by: d.id))

  defp hide!(user, fields) do
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: fields)
  end

  defp reporter! do
    reporter = insert(:activated_user)
    insert(:email, user: reporter)
    reporter
  end

  # A suspended member can no longer publish, so walking the strike ladder needs
  # one post (and therefore one case) per rung.
  defp report_new_post!(user, reporter, body) do
    post = insert(:post, user: user, body: body)
    Moderation.report_content(reporter, post, %{"category" => "spam"})
  end

  # Drives the queued row to its last allowed attempt, which is where the
  # deliverer gives up for good.
  defp exhaust_attempts do
    Repo.update_all(from(d in Delivery),
      set: [attempts: 7, next_attempt_at: DateTime.add(DateTime.utc_now(:second), -1)]
    )

    assert Fediverse.deliver_due() == 1
    assert Repo.aggregate(Delivery, :count) == 0
  end

  describe "revoke_post/1 addresses the servers that got the post" do
    test "the Delete reaches a server that has since unfollowed" do
      user = federating()
      follower_on(user, "gone.example")
      post = published_post(user)
      assert Repo.aggregate(PostDelivery, :count) == 1

      # The server drops the follow. Its copy of the post does not go with it,
      # which is exactly what a "send it to whoever follows now" Delete misses.
      :ok = Fediverse.remove_follower(user, "https://gone.example/users/x")
      assert Fediverse.delivery_inboxes(user) == []

      assert :ok = Fediverse.revoke_post(post)

      assert [delivery] = deliveries()
      assert delivery.inbox_uri == "https://gone.example/inbox"
      assert delivery.activity_json =~ ~s("type":"Delete")
      assert delivery.activity_json =~ ~s("type":"Tombstone")
    end

    test "the Tombstone names the id the post was published under, not the current one" do
      user = federating()
      follower_on(user, "social.example")
      post = published_post(user)
      published_id = Docs.note_url(user, post.id)

      # A rename (issue #1086) moves every future Note URL. Written straight to
      # the row: what is under test is the id inside the activity, not the flow
      # that changes a username.
      renamed =
        user
        |> Ecto.Changeset.change(username: "renamed#{System.unique_integer([:positive])}")
        |> Repo.update!()

      refute Docs.note_url(renamed, post.id) == published_id

      assert :ok = Fediverse.revoke_post(post)

      assert [delivery] = deliveries()
      assert delivery.activity_json =~ published_id
      refute delivery.activity_json =~ Docs.note_url(renamed, post.id)
    end

    test "the records are spent once the revocation is queued" do
      user = federating()
      follower_on(user, "social.example")
      post = published_post(user)

      assert :ok = Fediverse.revoke_post(post)
      assert Repo.aggregate(PostDelivery, :count) == 0
    end

    test "a post with no records falls back to the current followers, not to silence" do
      user = federating()
      post = published_post(user, "Published before anybody followed.")
      # Nothing was recorded, because there was no inbox to record.
      assert Repo.aggregate(PostDelivery, :count) == 0

      follower_on(user, "late.example")

      assert :ok = Fediverse.revoke_post(post)

      assert [delivery] = deliveries()
      assert delivery.inbox_uri == "https://late.example/inbox"
      assert delivery.activity_json =~ Docs.note_url(user, post.id)
    end

    test "a takedown is not blocked by the very state the takedown creates" do
      for fields <- [
            [frozen_at: NaiveDateTime.utc_now(:second)],
            [deactivated_at: NaiveDateTime.utc_now(:second)],
            [suspended_until: ~N[2099-01-01 00:00:00]]
          ] do
        user = federating()
        follower_on(user, "social.example")
        post = published_post(user)

        hide!(user, fields)
        refute Fediverse.federated?(Repo.reload!(user))

        assert :ok = Fediverse.revoke_post(post),
               "a #{inspect(fields)} account must still be able to withdraw a post"

        assert [_delivery] = deliveries()
        Repo.delete_all(Delivery)
      end
    end

    test "a member who moved their followers away can still withdraw" do
      user = federating()
      follower_on(user, "social.example")
      post = published_post(user)

      moved =
        user
        |> Ecto.Changeset.change(moved_to: "https://elsewhere.example/users/me")
        |> Repo.update!()

      assert Fediverse.moved?(moved)
      assert :ok = Fediverse.revoke_post(post)
      assert [_delivery] = deliveries()
    end

    test "nothing is sent for a member who never federated" do
      post = insert(:post, user: insert(:activated_user))

      assert :skip == Fediverse.revoke_post(post)
      assert deliveries() == []
    end
  end

  describe "the moderation freezer (the takedown paths that used to send nothing)" do
    test "a report that freezes a post withdraws the copies, and rejecting it publishes again" do
      user = federating()
      follower_on(user, "social.example")
      post = published_post(user)

      {:ok, case_record} =
        Moderation.report_content(reporter!(), post, %{"category" => "bullying"})

      assert Repo.reload!(post).frozen_at
      assert [withdrawal] = deliveries()
      assert withdrawal.activity_json =~ ~s("type":"Delete")

      Repo.delete_all(Delivery)

      # An unfounded report has to put the post back on the other servers too,
      # and a Delete leaves nothing there for an Update to change: it is a Create.
      {:ok, _} = Moderation.reject_case(case_record, insert(:activated_user, admin?: true))

      refute Repo.reload!(post).frozen_at
      assert [republish] = deliveries()
      assert republish.activity_json =~ ~s("type":"Create")
      assert Repo.aggregate(PostDelivery, :count) == 1
    end

    test "an upheld report leaves the withdrawal in place and sends nothing more" do
      user = federating()
      follower_on(user, "social.example")
      post = published_post(user)

      {:ok, case_record} = Moderation.report_content(reporter!(), post, %{"category" => "spam"})
      assert [_withdrawal] = deliveries()
      Repo.delete_all(Delivery)

      {:ok, _} = Moderation.uphold_case(case_record, insert(:activated_user, admin?: true))

      assert deliveries() == []
    end

    test "a permanent removal broadcasts the actor Delete" do
      user = federating()
      follower_on(user, "social.example")
      post = published_post(user)

      {:ok, case_record} = Moderation.report_content(reporter!(), post, %{"category" => "spam"})
      Repo.delete_all(Delivery)

      {:ok, _} =
        Moderation.remove_owner(case_record, insert(:activated_user, admin?: true), :deactivate)

      assert Repo.reload!(user).deactivated_at
      assert [broadcast] = deliveries()
      assert broadcast.activity_json =~ ~s("type":"Delete")
      assert broadcast.activity_json =~ Docs.actor_url(user)
    end

    test "the strike ladder broadcasts on the permanent third strike, not on the suspension" do
      user = federating()
      follower_on(user, "social.example")
      insert(:email, user: user)
      admin = insert(:activated_user, admin?: true)
      reporter = reporter!()

      # A warning, then a week's suspension: both temporary, so the network hears
      # nothing — a seven-day hiding must never read as "this account is gone".
      for level <- 1..2 do
        {:ok, case_record} = report_new_post!(user, reporter, "strike #{level}")
        Repo.delete_all(Delivery)
        {:ok, _} = Moderation.uphold_case(case_record, admin)

        refute Enum.any?(deliveries(), &(&1.activity_json =~ Docs.actor_url(user)))
      end

      assert Repo.reload!(user).suspended_until

      {:ok, case_record} = report_new_post!(user, reporter, "strike three")
      Repo.delete_all(Delivery)
      {:ok, _} = Moderation.uphold_case(case_record, admin)

      assert Repo.reload!(user).deactivated_at
      assert [broadcast] = deliveries()
      assert broadcast.activity_json =~ ~s("type":"Delete")
      assert broadcast.activity_json =~ Docs.actor_url(user)
    end
  end

  describe "reporting a reply from another network (the Flag)" do
    setup do
      author = federating(fediverse_replies?: true)
      post = create_post!(author, %{"body" => "Ask me anything."})
      Repo.delete_all(Delivery)

      :ok =
        Fediverse.record_reply(
          author,
          %{
            "type" => "Create",
            "actor" => @remote_actor,
            "to" => [@public],
            "object" => %{
              "id" => "#{@remote_actor}/statuses/1",
              "type" => "Note",
              "inReplyTo" => Docs.note_url(author, post.id),
              "content" => "<p>Rubbish.</p>",
              "to" => [@public]
            }
          },
          %{
            uri: @remote_actor,
            handle: "alice",
            name: "Alice Anders",
            inbox: "#{@remote_actor}/inbox"
          }
        )

      {:ok, author: author, note: Repo.one!(Note)}
    end

    test "the report is passed on to the origin server", %{author: author, note: note} do
      reporter = insert(:activated_user)

      assert :ok = Fediverse.report_note(note.id, reporter)

      assert [flag] = deliveries()
      assert flag.inbox_uri == "#{@remote_actor}/inbox"
      assert flag.activity_json =~ ~s("type":"Flag")
      # The reported object, and never who reported it: the Flag travels to a
      # stranger's moderators, so it is signed by the thread's owner and names
      # nobody here.
      assert flag.activity_json =~ note.object_uri
      assert flag.activity_json =~ Docs.actor_url(author)
      refute flag.activity_json =~ reporter.id

      assert %NoteEvent{} = Repo.get_by(NoteEvent, action: "flagged")
      assert %NoteEvent{} = Repo.get_by(NoteEvent, action: "reported")
    end

    test "the report stops at the border for a blocked server", %{note: note} do
      admin = insert(:activated_user, admin?: true)
      {:ok, _} = Fediverse.block_instance(%{"host" => "social.example"}, admin)

      # The block purged the note itself, so there is nothing left to report.
      assert {:error, :not_found} = Fediverse.report_note(note.id, insert(:activated_user))
      assert deliveries() == []
    end

    test "taking a reply off your own post tells nobody", %{author: author, note: note} do
      assert :ok = Fediverse.remove_note(note.id, author)

      assert deliveries() == []
      assert Repo.get_by(NoteEvent, action: "flagged") == nil
      assert %NoteEvent{} = Repo.get_by(NoteEvent, action: "removed_by_member")
    end

    test "a report the reporter may not file changes nothing", %{note: note} do
      Repo.update_all(from(n in Note, where: n.id == ^note.id), set: [audience: "direct"])

      assert {:error, :not_allowed} = Fediverse.report_note(note.id, insert(:activated_user))
      assert deliveries() == []
      assert Repo.aggregate(NoteEvent, :count) == 0
    end
  end

  describe "a takedown that never arrives" do
    setup do
      Application.put_env(:vutuv, :fediverse_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end
      )

      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
      :ok
    end

    test "is written to the ledger the operator reads" do
      user = federating()
      follower_on(user, "social.example")
      post = published_post(user)
      published_id = Docs.note_url(user, post.id)

      assert :ok = Fediverse.revoke_post(post)
      exhaust_attempts()

      assert [failure] = Repo.all(DeliveryFailure)
      assert failure.activity_type == "Delete"
      assert failure.host == "social.example"
      assert failure.object_uri == published_id
      assert failure.attempts == 8
      assert failure.last_error =~ "500"
      assert failure.user_id == user.id

      assert Fediverse.stats().failed_takedowns == 1
      assert [^failure] = Fediverse.recent_delivery_failures()
    end

    test "an ordinary post that did not travel is not in it" do
      user = federating()
      follower_on(user, "social.example")
      create_post!(user, %{"body" => "Hello out there."})
      assert [%Delivery{}] = deliveries()

      exhaust_attempts()

      assert Repo.all(DeliveryFailure) == []
      assert Fediverse.stats().failed_takedowns == 0
    end
  end

  describe "account deletion" do
    test "captures the actor Delete even for an account moderation had already hidden" do
      user = federating()
      follower_on(user, "social.example")
      hide!(user, deactivated_at: NaiveDateTime.utc_now(:second))
      hidden = Repo.reload!(user)

      refute Fediverse.federated?(hidden)
      assert %{inboxes: ["https://social.example/inbox"]} = Fediverse.prepare_actor_delete(hidden)
    end

    test "clears the delivery records the cascade cannot reach" do
      user = federating()
      follower_on(user, "social.example")
      published_post(user)
      assert Repo.aggregate(PostDelivery, :count) == 1

      assert 1 == Fediverse.drop_post_deliveries(user)
      assert Repo.aggregate(PostDelivery, :count) == 0
    end
  end

  describe "purge_instance/1" do
    test "forgets what a blocked server received" do
      user = federating()
      follower_on(user, "social.example")
      published_post(user)

      assert %{post_deliveries: 1} = Fediverse.purge_instance("social.example")
      assert Repo.aggregate(PostDelivery, :count) == 0
    end
  end
end

defmodule Vutuv.FediversePostLookupTest do
  @moduledoc """
  Looking a post on another network up by its URL (issue #1211): what is
  fetched, what is refused unseen, what costs nothing the second time, and what
  the resulting copy is allowed to outlive.

  `async: false` — the per-member lookup budget and the HTTP stub both live in
  application/ETS state the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.BlockedInstance
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.PostLookup
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  @author "https://fern.example/users/autorin"
  @object "https://fern.example/users/autorin/statuses/1"
  @display "https://fern.example/@autorin/1"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp member do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    Repo.reload!(user)
  end

  # The far server answering for the post and for its author. `calls` counts the
  # requests it saw, so a test can prove a lookup made none.
  defp serve(note_overrides \\ %{}) do
    test = self()

    note =
      Map.merge(
        %{
          "id" => @object,
          "type" => "Note",
          "attributedTo" => @author,
          "url" => @display,
          "content" => "<p>Ein Beitrag von vor der Zeit.</p>",
          "published" => "2026-06-11T09:00:00Z",
          "to" => [@public]
        },
        note_overrides
      )

    actor = %{
      "id" => @author,
      "type" => "Person",
      "preferredUsername" => "autorin",
      "name" => "Die Autorin",
      "inbox" => @author <> "/inbox"
    }

    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn ->
        send(test, {:fetched, conn.request_path})
        # The actor lives at exactly one path; everything else this stub is
        # asked for is the post — under its canonical id or its display URL.
        body = if conn.request_path == "/users/autorin", do: actor, else: note

        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp drain_fetches do
    receive do
      {:fetched, _path} -> drain_fetches()
    after
      0 -> :ok
    end
  end

  defp refuse_all do
    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 500, "") end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  describe "a public post" do
    test "is fetched by its display URL and stored under its canonical id" do
      serve()
      user = member()

      assert {:ok, %RemotePost{} = post} = Fediverse.look_up_post(user, @display)

      assert post.object_uri == @object
      assert post.origin_url == @display
      assert post.audience == "public"
      assert post.content_text =~ "Ein Beitrag von vor der Zeit."
      assert %RemoteAccount{handle: "autorin", host: "fern.example"} = post.remote_account

      # From receipt, not from publication: a post from June is not already
      # expired when it is looked up in July.
      assert DateTime.compare(post.expires_at, DateTime.utc_now()) == :gt
    end

    test "leaves a hold so the unfollowed purge spares it" do
      serve()
      user = member()

      assert {:ok, post} = Fediverse.look_up_post(user, @display)
      assert Repo.get_by(PostLookup, user_id: user.id, remote_post_id: post.id)

      # Nobody here follows the author, which is the ordinary case for a lookup.
      assert Fediverse.purge_unfollowed_remote_posts() == 0
      assert Repo.get(RemotePost, post.id)
    end

    test "buys no extra time: the ceiling still takes it" do
      serve()
      user = member()

      assert {:ok, post} = Fediverse.look_up_post(user, @display)

      Repo.update_all(
        from(p in RemotePost, where: p.id == ^post.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -60)]
      )

      assert Fediverse.expire_due_remote_posts() == 1
      refute Repo.get(RemotePost, post.id)
    end

    test "is answered from the cache the second time, with no request and no budget" do
      serve()
      user = member()

      assert {:ok, post} = Fediverse.look_up_post(user, @display)
      assert_received {:fetched, _}
      # Everything the first lookup asked for, so the assertion below is about
      # the second one alone.
      drain_fetches()
      refuse_all()

      # Either URL of the same post: the canonical id servers exchange, and the
      # display URL a member copies out of their browser.
      assert {:ok, %RemotePost{id: id}} = Fediverse.look_up_post(user, @object)
      assert id == post.id
      assert {:ok, %RemotePost{id: ^id}} = Fediverse.look_up_post(user, @display)

      refute_received {:fetched, _}
      assert Repo.aggregate(RemotePost, :count) == 1
    end

    test "is capped per member per hour" do
      serve()
      user = member()

      Application.put_env(:vutuv, :fediverse_lookup_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_lookup_limit) end)

      assert {:ok, _post} = Fediverse.look_up_post(user, @display)

      assert {:error, :lookup_capped} =
               Fediverse.look_up_post(user, "https://fern.example/@autorin/2")
    end
  end

  describe "what is refused" do
    test "a post its author addressed to their followers alone" do
      serve(%{"to" => [@author <> "/followers"], "cc" => []})

      assert {:error, :post_not_public} = Fediverse.look_up_post(member(), @display)
      assert Repo.aggregate(RemotePost, :count) == 0
    end

    test "a document claiming an author on another host" do
      serve(%{"attributedTo" => "https://andere.example/users/jemand"})

      assert {:error, :not_a_post} = Fediverse.look_up_post(member(), @display)
      assert Repo.aggregate(RemotePost, :count) == 0
    end

    test "anything that is not a post" do
      serve(%{"type" => "Video"})

      assert {:error, :not_a_post} = Fediverse.look_up_post(member(), @display)
    end

    test "a server the operator shut out, before any request is made" do
      serve()
      admin = insert(:activated_user)

      {:ok, _blocked} =
        Repo.insert(
          BlockedInstance.changeset(%BlockedInstance{blocked_by_id: admin.id}, %{
            host: "fern.example",
            reason: "test"
          })
        )

      assert {:error, :instance_blocked} = Fediverse.look_up_post(member(), @display)
      refute_received {:fetched, _}
    end

    test "a member who does not take part in the Fediverse" do
      serve()
      user = insert(:activated_user, fediverse_followers?: false)

      assert {:error, :not_federating} = Fediverse.look_up_post(user, @display)
      assert Fediverse.lookup_refusal(user) == :not_federating
      refute_received {:fetched, _}
    end

    test "a server that does not answer" do
      refuse_all()

      assert {:error, :post_unreachable} = Fediverse.look_up_post(member(), @display)
    end

    test "something that is not a link at all" do
      assert {:error, :invalid_post_url} = Fediverse.look_up_post(member(), "was ist das")
      assert {:error, :invalid_post_url} = Fediverse.look_up_post(member(), "   ")
    end
  end

  describe "what is not a remote post" do
    test "a vutuv post URL resolves to the local post" do
      author = insert(:activated_user)
      post = insert(:post, user: author)
      url = "#{VutuvWeb.Endpoint.url()}/#{author.username}/posts/#{post.id}"

      assert {:local, local} = Fediverse.look_up_post(member(), url)
      assert local.id == post.id
    end

    test "a vutuv link that is not a post says so rather than being fetched" do
      url = "#{VutuvWeb.Endpoint.url()}/some-member"

      assert {:error, :local_url} = Fediverse.look_up_post(member(), url)
    end

    test "an account address is handed on rather than refused" do
      assert {:account, "@autorin@fern.example"} =
               Fediverse.look_up_post(member(), "@autorin@fern.example")

      assert {:account, "https://fern.example/@autorin"} =
               Fediverse.look_up_post(member(), "https://fern.example/@autorin")
    end
  end

  describe "a post already here" do
    test "is returned without a fetch even when its author is followed" do
      serve()
      user = member()

      assert {:ok, post} = Fediverse.look_up_post(user, @display)

      Repo.insert!(%Follow{
        user_id: user.id,
        remote_account_id: post.remote_account_id,
        state: "accepted",
        follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/1"
      })

      refuse_all()
      assert {:ok, %RemotePost{id: id}} = Fediverse.look_up_post(user, @display)
      assert id == post.id
    end
  end
end

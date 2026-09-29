defmodule Vutuv.FediverseRemoteMentionsTest do
  @moduledoc """
  A post naming `@doris@friendica.example` resolves that account, tells her
  server with a `Mention` (so she is notified), delivers the post to her, and
  keeps her account row so the mention links to her real profile page.

  async: false — the HTTP stub is the global `:fediverse_req_options`, which
  every outbound fetch in `Vutuv.Fediverse` reads.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.FediverseHelpers, only: [stub_remote: 1]

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.PostRemoteMention
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Mentions
  alias Vutuv.Posts
  alias VutuvWeb.Fediverse.Docs

  @actor "https://friendica.example/profile/doris"
  @inbox "https://friendica.example/inbox/doris"
  @shared_inbox "https://friendica.example/inbox"

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

  # Doris's server: her WebFinger names her actor, her actor names her inbox
  # and her profile page. Counts the requests, so a test can say none were made.
  defp serve_doris do
    counter = :counters.new(1, [])

    stub_remote(fn conn ->
      :counters.add(counter, 1, 1)

      case conn.request_path do
        "/.well-known/webfinger" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/jrd+json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "subject" => "acct:doris@friendica.example",
              "links" => [
                %{"rel" => "self", "type" => "application/activity+json", "href" => @actor}
              ]
            })
          )

        "/profile/doris" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/activity+json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "id" => @actor,
              "type" => "Person",
              "preferredUsername" => "doris",
              "inbox" => @inbox,
              "endpoints" => %{"sharedInbox" => @shared_inbox},
              "url" => @actor
            })
          )
      end
    end)

    counter
  end

  defp stored_account do
    Repo.insert!(%RemoteAccount{
      actor_uri: @actor,
      host: "friendica.example",
      handle: "doris",
      inbox_uri: @inbox
    })
  end

  defp mentions(post),
    do: Repo.all(from(m in PostRemoteMention, where: m.post_id == ^post.id, order_by: m.address))

  defp note(post, user) do
    post |> Repo.preload(Docs.note_preloads(), force: true) |> Docs.note(user)
  end

  describe "reading the addresses" do
    test "finds foreign addresses, lowercased, and skips code and our own hosts" do
      host = VutuvWeb.Endpoint.host()

      assert Mentions.remote_addresses(
               "Hallo @Doris@Friendica.example und @ada@#{host}, `@code@x.example`"
             ) == ["doris@friendica.example"]
    end
  end

  describe "saving a post" do
    test "a held account is linked at once and needs no request", %{user: user} do
      account = stored_account()
      counter = serve_doris()

      {:ok, post} = Posts.create_post(user, %{body: "Danke @doris@friendica.example!"})

      assert [%PostRemoteMention{remote_account_id: id}] = mentions(post)
      assert id == account.id
      assert :counters.get(counter, 1) == 0
    end

    test "an unknown account waits for its resolve, and so does the post", %{user: user} do
      {:ok, post} = Posts.create_post(user, %{body: "Danke @doris@friendica.example!"})

      assert [%PostRemoteMention{remote_account_id: nil, address: "doris@friendica.example"}] =
               mentions(post)

      # Its followers' copy is held so that it can carry the Mention.
      assert [%Delivery{rebuild_from: marker, next_attempt_at: due}] = Repo.all(Delivery)
      assert marker == "post_create:#{post.id}"
      assert DateTime.after?(due, DateTime.utc_now())
    end

    test "an edit drops an address the body no longer names", %{user: user} do
      stored_account()
      {:ok, post} = Posts.create_post(user, %{body: "Danke @doris@friendica.example!"})

      {:ok, post} = Posts.update_post(post, %{body: "Danke euch allen!"})

      assert mentions(post) == []
    end

    test "at most five addresses count", %{user: user} do
      body = Enum.map_join(1..7, " ", &"@u#{&1}@host#{&1}.example")
      {:ok, post} = Posts.create_post(user, %{body: body})

      assert length(mentions(post)) == 5
    end
  end

  describe "resolving" do
    test "stores the account, tags the Note and delivers the post to her", %{user: user} do
      serve_doris()
      {:ok, post} = Posts.create_post(user, %{body: "Danke @doris@friendica.example!"})

      assert :ok = Fediverse.resolve_remote_mentions(post.id)

      account = Repo.get_by!(RemoteAccount, actor_uri: @actor)
      assert account.profile_url == @actor
      assert [%PostRemoteMention{remote_account_id: id}] = mentions(post)
      assert id == account.id

      note = note(post, user)

      assert %{"type" => "Mention", "href" => @actor, "name" => "@doris@friendica.example"} in note[
               "tag"
             ]

      assert @actor in note["cc"]

      # Her own copy, and the followers' copy let go at once.
      deliveries = Repo.all(from(d in Delivery, order_by: d.id))

      assert Enum.map(deliveries, & &1.inbox_uri) == [
               "https://follower.example/inbox",
               @shared_inbox
             ]

      assert Enum.all?(
               deliveries,
               &(DateTime.compare(&1.next_attempt_at, DateTime.utc_now()) != :gt)
             )
    end

    # Her server already has the post (a follower there, the hold ran out), and
    # a second Create of a post it holds is ignored: only an Update carries the
    # new Mention to her.
    test "a server that already has the post gets the Update", %{user: user} do
      serve_doris()

      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: "https://friendica.example/profile/max",
          inbox_uri: "https://friendica.example/inbox/max",
          shared_inbox_uri: @shared_inbox
        })

      {:ok, post} = Posts.create_post(user, %{body: "Danke @doris@friendica.example!"})
      # The held copies went out untagged and left the queue.
      Repo.delete_all(Delivery)

      Fediverse.resolve_remote_mentions(post.id)

      assert [%Delivery{inbox_uri: @shared_inbox, activity_json: json}] =
               Repo.all(Delivery)

      assert json =~ ~s("type":"Update")
      assert json =~ @actor
    end

    test "the account stays while a post names it" do
      account = stored_account()
      post = insert(:post, body: "@doris@friendica.example")

      Repo.insert!(%PostRemoteMention{
        post_id: post.id,
        remote_account_id: account.id,
        address: "doris@friendica.example"
      })

      Fediverse.purge_unreferenced_remote_accounts()

      assert Repo.get(RemoteAccount, account.id)
    end

    test "a member who keeps out of the Fediverse still gets the right link, but sends nothing" do
      serve_doris()
      user = insert(:activated_user)
      {:ok, post} = Posts.create_post(user, %{body: "@doris@friendica.example"})

      Fediverse.resolve_remote_mentions(post.id)

      assert [%PostRemoteMention{remote_account_id: id}] = mentions(post)
      assert id
      assert Repo.all(Delivery) == []
    end
  end

  describe "the sweeper" do
    # The task a deploy killed: the row is pending, no attempt was ever
    # stamped, and it is older than the retry window.
    defp orphaned_mention(post) do
      old = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3_600)

      Repo.insert!(%PostRemoteMention{
        post_id: post.id,
        address: "doris@friendica.example",
        inserted_at: old,
        updated_at: old
      })
    end

    test "finishes a resolve whose task died", %{user: user} do
      serve_doris()
      post = insert(:post, user: user, body: "@doris@friendica.example")
      mention = orphaned_mention(post)

      assert Fediverse.resolve_stale_remote_mentions() == 1

      assert Repo.reload!(mention).remote_account_id
      assert Enum.any?(Repo.all(Delivery), &(&1.inbox_uri == @shared_inbox))
    end

    test "leaves a fresh row to its own task", %{user: user} do
      serve_doris()
      post = insert(:post, user: user, body: "@doris@friendica.example")
      Repo.insert!(%PostRemoteMention{post_id: post.id, address: "doris@friendica.example"})

      assert Fediverse.resolve_stale_remote_mentions() == 0
    end

    # The sweeper-clock rule: a failure must stamp the row, or it holds the
    # front of every batch for ever.
    test "an address that cannot be resolved is no longer due after one try", %{user: user} do
      stub_remote(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      post = insert(:post, user: user, body: "@doris@friendica.example")
      mention = orphaned_mention(post)

      assert Fediverse.resolve_stale_remote_mentions() == 0

      mention = Repo.reload!(mention)
      assert mention.attempts == 1
      assert mention.attempted_at
      assert Fediverse.resolve_stale_remote_mentions() == 0
      assert Repo.reload!(mention).attempts == 1
    end
  end
end

defmodule VutuvWeb.FediverseTagActorWebTest do
  @moduledoc """
  A topic's ActivityPub identity (issue #1330): anyone on any server can follow
  a tag, and never needs an account here to do it.

  Everything lives on the **tag host**, `tags.<our host>`, which is its own
  WebFinger authority. That is not tidiness: members and pages share one handle
  namespace, tags are member-creatable, and `ReservedSlugs` guards only route
  words — so a tag `elixir` and a member `elixir` would otherwise want the same
  address. And the actor's **id** has to be on that host too, because Mastodon
  confirms an account by re-resolving `preferredUsername@<host of the actor
  id>`: an id on the apex would canonicalise the handle straight back into the
  namespace the subdomain exists to avoid.

  `async: false`: it points `:fediverse_tag_host` at a known host for the
  duration, which is global.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follower
  alias Vutuv.Tags.Tag

  @tag_host "tags.example.test"

  # Same scheme and port as the endpoint, with the tag host in its place — a dev
  # server on :4000 and production both have to produce a reachable URL.
  defp tag_base do
    %URI{URI.parse(String.trim_trailing(VutuvWeb.Endpoint.url(), "/")) | host: @tag_host}
    |> URI.to_string()
  end

  setup do
    original = Application.fetch_env(:vutuv, :fediverse_tag_host)
    Application.put_env(:vutuv, :fediverse_tag_host, @tag_host)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :fediverse_tag_host, was)
        :error -> Application.delete_env(:vutuv, :fediverse_tag_host)
      end
    end)

    :ok
  end

  defp topic do
    n = System.unique_integer([:positive])
    insert(:tag, name: "Elixir #{n}", slug: "elixir_#{n}")
  end

  defp site_url, do: String.trim_trailing(VutuvWeb.Endpoint.url(), "/")

  # A request as it arrives on the tag host: same app, different `Host` header.
  defp on_tag_host(conn), do: %{conn | host: @tag_host}

  defp ap(conn), do: put_req_header(conn, "accept", "application/activity+json")

  # A request as a person makes it. Every browser puts `text/html` in its
  # Accept, and on this host that is the whole distinction: there is nothing
  # here a human reads.
  defp in_browser(conn), do: put_req_header(conn, "accept", "text/html,application/xhtml+xml,*/*")

  describe "the address" do
    test "WebFinger on the tag host resolves a topic to its actor", %{conn: conn} do
      tag = topic()

      json =
        conn
        |> on_tag_host()
        |> get(~p"/.well-known/webfinger", resource: "acct:#{tag.slug}@#{@tag_host}")
        |> json_response(200)

      assert json["subject"] == "acct:#{tag.slug}@#{@tag_host}"

      self_link = Enum.find(json["links"], &(&1["rel"] == "self"))
      assert self_link["href"] == "#{tag_base()}/#{tag.slug}"
    end

    test "the actor says Group and carries its own key", %{conn: conn} do
      tag = topic()

      json = conn |> on_tag_host() |> ap() |> get("/#{tag.slug}") |> json_response(200)

      assert json["type"] == "Group"
      assert json["preferredUsername"] == tag.slug
      assert json["name"] == tag.name
      assert json["publicKey"]["publicKeyPem"] =~ "PUBLIC KEY"

      # The id and the handle agree, which is what makes the account resolvable
      # from the other side at all.
      assert json["id"] == "#{tag_base()}/#{tag.slug}"
      assert URI.parse(json["id"]).host == @tag_host

      # The human page stays on the main host: that is where a reader goes.
      assert json["url"] =~ "/tags/#{tag.slug}"
    end

    test "every collection the document names actually answers", %{conn: conn} do
      tag = topic()

      json = conn |> on_tag_host() |> ap() |> get("/#{tag.slug}") |> json_response(200)

      for key <- ~w(followers outbox) do
        path = URI.parse(json[key]).path
        assert conn |> on_tag_host() |> ap() |> get(path) |> json_response(200)
      end
    end

    test "an alias is not a second address for the same posts", %{conn: conn} do
      canonical = topic()
      n = System.unique_integer([:positive])

      other_name =
        insert(:tag, name: "Alias #{n}", slug: "alias_#{n}", merged_into_id: canonical.id)

      assert conn |> on_tag_host() |> ap() |> get("/#{other_name.slug}") |> response(404)

      assert conn
             |> on_tag_host()
             |> get(~p"/.well-known/webfinger", resource: "acct:#{other_name.slug}@#{@tag_host}")
             |> response(404)
    end

    test "the same slug on the MAIN host is not a tag actor", %{conn: conn} do
      tag = topic()

      # The whole point of the separate authority: on the main host that address
      # belongs to the member/page namespace, and no tag may answer for it.
      assert conn
             |> get(~p"/.well-known/webfinger", resource: "acct:#{tag.slug}@#{conn.host}")
             |> response(404)
    end
  end

  describe "a person who lands here" do
    # The tag host carries actors and nothing anybody reads, but the app behind
    # it is the same one — so until this, every route the host had not claimed
    # simply answered: `https://tags.vutuv.de/` rendered the whole start page,
    # a second copy of the site under a hostname no reader was meant to see,
    # and `/<tag>` handed a browser raw ActivityPub JSON.
    test "the tag host has no start page of its own", %{conn: conn} do
      conn = conn |> on_tag_host() |> in_browser() |> get("/")

      assert redirected_to(conn, 301) == site_url() <> "/"
    end

    test "a page of the site keeps its path and its query on the way over", %{conn: conn} do
      conn = conn |> on_tag_host() |> in_browser() |> get("/system/members?letter=m")

      assert redirected_to(conn, 301) == site_url() <> "/system/members?letter=m"
    end

    test "the main host is left alone", %{conn: conn} do
      assert conn |> in_browser() |> get(~p"/") |> html_response(200)
    end

    test "a topic's address opens the topic, not the start page", %{conn: conn} do
      tag = topic()

      # Somebody reading `@elixir@tags.<host>` in another network's timeline
      # clicks the actor's own address. Dropping them on the start page would
      # make them search for the thing they just clicked.
      conn = conn |> on_tag_host() |> in_browser() |> get("/#{tag.slug}")

      assert redirected_to(conn, 301) == site_url() <> "/tags/#{tag.slug}"
    end

    test "an alternative name leads to the topic it names", %{conn: conn} do
      canonical = topic()
      n = System.unique_integer([:positive])
      other = insert(:tag, name: "Alias #{n}", slug: "alias_#{n}", merged_into_id: canonical.id)

      conn = conn |> on_tag_host() |> in_browser() |> get("/#{other.slug}")

      assert redirected_to(conn, 301) == site_url() <> "/tags/#{canonical.slug}"
    end

    test "an address that names no topic goes to the start page, and not for good",
         %{conn: conn} do
      conn =
        conn
        |> on_tag_host()
        |> in_browser()
        |> get("/kotlin_#{System.unique_integer([:positive])}")

      # 302: that word names the start page only until somebody creates the
      # tag, and a permanent redirect a browser had cached would keep the
      # reader from ever reaching it.
      assert redirected_to(conn, 302) == site_url() <> "/"
    end

    test "the collections a reader stumbles into lead to the topic too", %{conn: conn} do
      tag = topic()

      for path <- ["/#{tag.slug}/followers", "/#{tag.slug}/outbox"] do
        conn = conn |> on_tag_host() |> in_browser() |> get(path)
        assert redirected_to(conn, 301) == site_url() <> "/tags/#{tag.slug}"
      end
    end

    # The calibration: of the two ways to read a request wrong here, only one
    # is silent. A reader sent the actor document sees JSON and shrugs; a
    # remote server sent a redirect stops being able to follow the topic, and
    # nothing here would say so. So the question asked is "did this client ask
    # for HTML", never "did it fail to ask for ActivityPub" — a fetch carrying
    # `*/*`, or no Accept at all, keeps getting the actor.
    test "a server that names no format still gets the actor", %{conn: conn} do
      tag = topic()

      for accept <- [nil, "*/*", "application/ld+json"] do
        request = conn |> on_tag_host()
        request = if accept, do: put_req_header(request, "accept", accept), else: request

        assert request |> get("/#{tag.slug}") |> json_response(200)
      end
    end

    test "a delivery is never redirected, whatever it says it accepts", %{conn: conn} do
      tag = topic()

      # An unsigned POST is refused (401) — what matters is that it was
      # *answered* here rather than sent to the main host, where the tag
      # inbox does not exist.
      assert conn
             |> on_tag_host()
             |> in_browser()
             |> post("/#{tag.slug}/inbox", %{"type" => "Follow"})
             |> response(401)
    end
  end

  describe "following it" do
    test "a signed Follow is recorded and answered with an Accept", %{conn: conn} do
      tag = topic()
      {:ok, _} = Fediverse.ensure_tag_actor(tag)

      remote = %{
        id: "https://remote.example/users/frida",
        inbox: "https://remote.example/users/frida/inbox",
        shared_inbox: nil,
        handle: "@frida@remote.example",
        name: "Frida"
      }

      # The inbox verifies a signature, which this test has no key for. What it
      # can check is the half that decides what a verified Follow *does*, and
      # that is the half with the rules in it.
      assert {:ok, %Follower{} = row} =
               Fediverse.add_tag_follower(tag, %{
                 actor_uri: remote.id,
                 inbox_uri: remote.inbox,
                 handle: remote.handle,
                 name: remote.name
               })

      assert row.tag_id == tag.id
      assert Fediverse.tag_remote_follower_count(tag) == 1

      # Answering is not optional politeness: unanswered, the other side shows
      # "pending" forever.
      assert :ok =
               Fediverse.accept_follow(
                 tag,
                 %{"type" => "Follow", "actor" => remote.id},
                 remote.inbox
               )

      assert [delivery] = Repo.all(Vutuv.Fediverse.Delivery)
      assert delivery.tag_id == tag.id
      assert delivery.inbox_uri == remote.inbox

      accept = Jason.decode!(delivery.activity_json)
      assert accept["type"] == "Accept"
      assert accept["actor"] == "#{tag_base()}/#{tag.slug}"

      # And the collection the actor advertises now says so.
      json =
        conn |> on_tag_host() |> ap() |> get("/#{tag.slug}/followers") |> json_response(200)

      assert json["totalItems"] == 1
    end

    test "an Undo drops the follower again", %{conn: conn} do
      tag = topic()
      actor = "https://remote.example/users/frida"

      {:ok, _} =
        Fediverse.add_tag_follower(tag, %{
          actor_uri: actor,
          inbox_uri: "https://remote.example/users/frida/inbox"
        })

      assert Fediverse.remove_tag_follower(tag, actor) == 1

      json =
        conn |> on_tag_host() |> ap() |> get("/#{tag.slug}/followers") |> json_response(200)

      assert json["totalItems"] == 0
    end

    test "the same account following twice stays one follower" do
      tag = topic()

      attrs = %{
        actor_uri: "https://remote.example/users/frida",
        inbox_uri: "https://remote.example/users/frida/inbox"
      }

      assert {:ok, _} = Fediverse.add_tag_follower(tag, attrs)
      assert {:ok, _} = Fediverse.add_tag_follower(tag, attrs)

      # A server that re-delivers its Follow must not double the count.
      assert Fediverse.tag_remote_follower_count(tag) == 1
    end
  end

  describe "the host predicates" do
    test "the tag host is us, and `local_path/1` still says nothing about it" do
      assert Fediverse.tag_host?(@tag_host)
      assert Fediverse.own_host?(@tag_host)
      assert Fediverse.own_host?(VutuvWeb.Endpoint.host())

      # The narrow one must stay narrow: `local_path/1` shares it and asks which
      # member or page a URL names, and a tag-host URL names neither.
      refute Fediverse.local_host?(@tag_host)
      refute Fediverse.local_path("https://#{@tag_host}/elixir")
    end

    test "a tag-host address is refused as a remote follow target" do
      user = insert(:activated_user, fediverse_followers?: true)

      # Signing a request to ourselves and waiting for an Accept our own inbox
      # would have to invent is the failure v7.197.0 produced once, via `www.`.
      assert {:error, :local_account} =
               Fediverse.follow_remote(user, "@elixir@#{@tag_host}")
    end
  end

  test "a topic that is an alias federates nothing" do
    canonical = topic()
    n = System.unique_integer([:positive])
    other = insert(:tag, name: "Alias #{n}", slug: "alias_#{n}", merged_into_id: canonical.id)

    refute Fediverse.federated?(other)
    assert Fediverse.federated?(%Tag{canonical | merged_into_id: nil})
  end
end

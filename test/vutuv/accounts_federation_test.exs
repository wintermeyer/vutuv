defmodule Vutuv.AccountsFederationTest do
  # Deleting a federating member broadcasts an actor Delete to their remote
  # followers before the rows cascade away (issue #985). async: false — the HTTP
  # stub and the SSRF resolver live in the application env.
  use Vutuv.DataCase, async: false

  alias Vutuv.Accounts
  alias Vutuv.Fediverse
  alias VutuvWeb.Fediverse.Docs

  defp stub_remote(fun) do
    Application.put_env(:vutuv, :fediverse_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp federating_member_with_follower(inbox) do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _} = Fediverse.ensure_actor(user)

    {:ok, _} =
      Fediverse.add_follower(user, %{
        actor_uri: "https://social.example/users/alice",
        inbox_uri: inbox
      })

    user
  end

  test "deleting a federating member POSTs a signed actor Delete to each follower inbox" do
    parent = self()

    stub_remote(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:delivered, conn.request_path, Map.new(conn.req_headers), body})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    user = federating_member_with_follower("https://social.example/users/alice/inbox")

    assert {:ok, _} = Accounts.delete_user(user)

    assert_receive {:delivered, "/users/alice/inbox", headers, body}
    assert headers["signature"] =~ ~s(keyId="#{Docs.key_id(user)}")
    assert headers["digest"] =~ "SHA-256="
    assert headers["content-type"] =~ "application/activity+json"

    activity = Jason.decode!(body)
    assert activity["type"] == "Delete"
    assert activity["actor"] == Docs.actor_url(user)
    assert activity["object"] == Docs.actor_url(user)

    # The account really is gone regardless of the Fediverse side.
    refute Accounts.get_user(user.id)
  end

  test "one Delete per distinct inbox, deduped by the shared inbox" do
    parent = self()

    stub_remote(fn conn ->
      send(parent, {:hit, conn.request_path})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _} = Fediverse.ensure_actor(user)

    for name <- ~w(alice bob) do
      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: "https://social.example/users/#{name}",
          inbox_uri: "https://social.example/users/#{name}/inbox",
          shared_inbox_uri: "https://social.example/inbox"
        })
    end

    {:ok, _} =
      Fediverse.add_follower(user, %{
        actor_uri: "https://other.example/users/carol",
        inbox_uri: "https://other.example/users/carol/inbox"
      })

    assert {:ok, _} = Accounts.delete_user(user)

    assert_receive {:hit, "/inbox"}
    assert_receive {:hit, "/users/carol/inbox"}
    refute_receive {:hit, _}
  end

  test "deleting a non-federating member sends nothing" do
    parent = self()
    stub_remote(fn conn -> send(parent, :hit) && Plug.Conn.send_resp(conn, 202, "") end)

    # Opted out of federation, but even with a stray follower row present.
    plain = insert(:activated_user)

    assert {:ok, _} = Accounts.delete_user(plain)
    refute_receive :hit
  end

  test "deletion still succeeds when the Fediverse broadcast fails" do
    stub_remote(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    user = federating_member_with_follower("https://social.example/users/alice/inbox")

    assert {:ok, _} = Accounts.delete_user(user)
    refute Accounts.get_user(user.id)
  end
end

defmodule VutuvWeb.MastodonApi.MarkersTest do
  @moduledoc """
  Where a client left off reading (`/api/v1/markers`).

  `GET` answered a bare `{}` and there was no `POST` at all — which also meant
  the write fell through to the website's HTML error page — so a position was
  never stored and never restored. Relaunching an app dropped its timeline back
  to whatever it could fetch, which is what a member reads as a timeline that
  lost everything it had.
  """
  use VutuvWeb.ConnCase

  import Vutuv.MastodonHelpers

  alias Vutuv.MastodonApi.Marker
  alias Vutuv.MastodonApi.Markers
  alias Vutuv.Organizations
  alias Vutuv.Repo

  setup do
    member = insert(:activated_user)
    {:ok, member: member, token: mastodon_token(member, ["read", "write"])}
  end

  test "nothing recorded is an empty object, not an error", %{conn: conn, token: token} do
    assert conn |> mastodon_conn(token) |> get("/api/v1/markers") |> json_response(200) == %{}
  end

  test "a recorded position comes back", %{conn: conn, token: token} do
    written =
      conn
      |> mastodon_conn(token)
      |> post("/api/v1/markers", %{"home" => %{"last_read_id" => "01a0-abc"}})
      |> json_response(200)

    assert written["home"]["last_read_id"] == "01a0-abc"
    assert written["home"]["version"] == 1

    read = build_conn() |> mastodon_conn(token) |> get("/api/v1/markers") |> json_response(200)

    assert read["home"]["last_read_id"] == "01a0-abc"
  end

  test "writing again moves it and counts the write", %{conn: conn, token: token} do
    conn |> mastodon_conn(token) |> post("/api/v1/markers", %{"home" => %{"last_read_id" => "a"}})

    second =
      build_conn()
      |> mastodon_conn(token)
      |> post("/api/v1/markers", %{"home" => %{"last_read_id" => "b"}})
      |> json_response(200)

    assert second["home"]["last_read_id"] == "b"
    # Mastodon's own counter, which a client reads to tell its echo from another
    # device's write.
    assert second["home"]["version"] == 2
  end

  test "both timelines are kept apart", %{conn: conn, token: token} do
    conn
    |> mastodon_conn(token)
    |> post("/api/v1/markers", %{
      "home" => %{"last_read_id" => "h1"},
      "notifications" => %{"last_read_id" => "n1"}
    })

    read = build_conn() |> mastodon_conn(token) |> get("/api/v1/markers") |> json_response(200)

    assert read["home"]["last_read_id"] == "h1"
    assert read["notifications"]["last_read_id"] == "n1"
  end

  test "a client can ask for one of them", %{conn: conn, token: token} do
    conn
    |> mastodon_conn(token)
    |> post("/api/v1/markers", %{
      "home" => %{"last_read_id" => "h1"},
      "notifications" => %{"last_read_id" => "n1"}
    })

    read =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v1/markers", %{"timeline" => ["home"]})
      |> json_response(200)

    assert Map.keys(read) == ["home"]
  end

  test "an unknown timeline is skipped, and its good half still stored", %{
    conn: conn,
    token: token
  } do
    # A client sending one of each in the same request must not lose the one we
    # understand.
    written =
      conn
      |> mastodon_conn(token)
      |> post("/api/v1/markers", %{
        "home" => %{"last_read_id" => "h1"},
        "wishlist" => %{"last_read_id" => "x"}
      })
      |> json_response(200)

    assert Map.keys(written) == ["home"]
  end

  test "an id whose entry is since gone is still a valid bookmark", %{conn: conn, token: token} do
    # Stored as sent, prefix and all: the ids this adapter mints are not all
    # uuids, and a bookmark into a deleted post must not fail a write.
    written =
      conn
      |> mastodon_conn(token)
      |> post("/api/v1/markers", %{"home" => %{"last_read_id" => "remote-01a0-deleted"}})
      |> json_response(200)

    assert written["home"]["last_read_id"] == "remote-01a0-deleted"
  end

  test "one member's position is not another's", %{conn: conn, token: token} do
    conn |> mastodon_conn(token) |> post("/api/v1/markers", %{"home" => %{"last_read_id" => "a"}})

    other = mastodon_token(insert(:activated_user), ["read"])

    assert build_conn() |> mastodon_conn(other) |> get("/api/v1/markers") |> json_response(200) ==
             %{}
  end

  test "a page's position belongs to the page, not to whoever read for it", %{
    conn: conn,
    member: member
  } do
    organization = insert(:organization)
    {:ok, organization} = Organizations.set_mastodon_clients(organization, true)
    {:ok, _} = Organizations.add_role(organization, member, "publisher", member)
    token = mastodon_token(member, ["read", "write"], organization)

    assert conn
           |> mastodon_conn(token)
           |> post("/api/v1/markers", %{"home" => %{"last_read_id" => "page-position"}})
           |> json_response(200)

    # The page's, so two publishers reading it from their own phones share one
    # position — the same way they share the page's feed.
    assert %{"home" => marker} = Markers.get({member, organization})
    assert marker.last_read_id == "page-position"

    # And the member's own timeline is untouched by it.
    assert Markers.get(member) == %{}
  end

  test "a page has one row however many publishers write it", %{conn: conn, member: member} do
    # The read is scoped to the organization alone, so the uniqueness has to be
    # too. While the index also named `user_id`, two publishers writing in the
    # same instant each inserted their own row — and every later read raised
    # `Ecto.MultipleResultsError`, which is a 500 on that page's markers for
    # good. Restoring `[:user_id, :organization_id, :timeline]` in the
    # migration turns this red.
    organization = insert(:organization)
    {:ok, organization} = Organizations.set_mastodon_clients(organization, true)
    colleague = insert(:activated_user)

    for reader <- [member, colleague] do
      {:ok, _} = Organizations.add_role(organization, reader, "publisher", member)
    end

    Markers.put({member, organization}, %{"home" => %{"last_read_id" => "first"}})

    # What the losing side of that race attempts: a blind insert, having read
    # no row of its own.
    assert {:error, changeset} =
             Repo.insert(
               Ecto.Changeset.change(%Marker{},
                 user_id: colleague.id,
                 organization_id: organization.id,
                 timeline: "home",
                 last_read_id: "second"
               )
               |> Ecto.Changeset.unique_constraint([:organization_id, :timeline],
                 name: :mastodon_markers_organization_timeline_index
               )
             )

    assert changeset.errors != []
    assert Repo.aggregate(Marker, :count) == 1

    # And the colleague writing through the endpoint moves the page's one
    # position rather than raising.
    token = mastodon_token(colleague, ["read", "write"], organization)

    assert conn
           |> mastodon_conn(token)
           |> post("/api/v1/markers", %{"home" => %{"last_read_id" => "second"}})
           |> json_response(200)

    assert %{"home" => marker} = Markers.get({member, organization})
    assert marker.last_read_id == "second"
    assert marker.version == 2
    assert Repo.aggregate(Marker, :count) == 1
  end
end

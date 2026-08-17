defmodule VutuvWeb.OrganizationRemoteFollowWebTest do
  @moduledoc """
  Following an account on another network **as a page** (issue #1336), from the
  page's Follows list.

  It lives there rather than on the Fediverse page beside it: a member's
  equivalent sits under their fediverse settings because their own following
  list is public and about people here, while this page is already
  publishers-only and already mixes members, pages and topics. One list of what
  the page reads is the honest shape, and it is exactly what its feed is built
  from.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the remote fetch is stubbed through
  the application env.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Organizations
  alias Vutuv.Repo
  alias VutuvWeb.Fediverse.Docs

  @actor "https://social.example/users/alice"

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp publishing_page(conn, opts \\ []) do
    {conn, owner} = create_and_login_user(conn)
    page = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)

    page =
      page
      |> Ecto.Changeset.change(Enum.into(opts, %{fediverse_followers?: true, username: "acme"}))
      |> Repo.update!()

    if page.fediverse_followers?, do: {:ok, _} = Fediverse.ensure_organization_actor(page)
    {conn, page}
  end

  defp existing_follow(page) do
    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: @actor,
        host: "social.example",
        inbox_uri: @actor <> "/inbox",
        handle: "@alice@social.example",
        name: "Alice"
      })

    id = Vutuv.UUIDv7.generate()

    Repo.insert!(%Follow{
      id: id,
      organization_id: page.id,
      remote_account_id: account.id,
      state: "requested",
      follow_activity_id: Docs.follow_activity_id(page, id)
    })
  end

  test "the section lists what the page follows out there, and says Requested", %{conn: conn} do
    {conn, page} = publishing_page(conn)
    existing_follow(page)

    html = conn |> get(~p"/organizations/#{page.slug}/following") |> html_response(200)

    assert html =~ "organization-remote-follows"
    assert html =~ "@alice@social.example"

    # "Requested" is the truth until the other server answers, and an account
    # that approves by hand may never do so.
    assert html =~ "Requested"
  end

  test "a publisher can withdraw one", %{conn: conn} do
    {conn, page} = publishing_page(conn)
    follow = existing_follow(page)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}/following")
    render_click(view, "unfollow-remote", %{"id" => follow.id})

    refute Repo.get(Follow, follow.id)
  end

  test "a publisher can mute and unmute a remote follow", %{conn: conn} do
    {conn, page} = publishing_page(conn)
    follow = existing_follow(page)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}/following")
    render_click(view, "mute-remote", %{"id" => follow.remote_account_id})
    assert Repo.reload!(follow).muted

    render_click(view, "unmute-remote", %{"id" => follow.remote_account_id})
    refute Repo.reload!(follow).muted
  end

  test "one page cannot withdraw another page's follow", %{conn: conn} do
    {conn, page} = publishing_page(conn)

    other =
      active_organization_for(insert(:activated_user), %{
        "name" => "Zweite AG",
        "website_url" => "https://zweite.example"
      })
      |> Ecto.Changeset.change(%{fediverse_followers?: true, username: "zweite"})
      |> Repo.update!()

    foreign = existing_follow(other)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}/following")
    render_click(view, "unfollow-remote", %{"id" => foreign.id})

    assert Repo.get(Follow, foreign.id)
  end

  test "a refused address keeps what was typed and says why", %{conn: conn} do
    {conn, page} = publishing_page(conn)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}/following")

    html =
      render_submit(view, "follow-remote", %{
        "remote_follow" => %{"address" => "not-an-address"}
      })

    # The box keeps the text: a refusal is usually a typo, and emptying it would
    # make the reader retype what they just wrote.
    assert html =~ "not-an-address"
    refute html =~ "invalid_address"
  end

  test "a page that does not federate is offered no box at all", %{conn: conn} do
    {conn, page} = publishing_page(conn, fediverse_followers?: false)

    html = conn |> get(~p"/organizations/#{page.slug}/following") |> html_response(200)

    # Without an actor there is nothing to sign a Follow with, so the control
    # could only ever refuse.
    refute html =~ "organization-remote-follows"
  end

  test "the section reads as German", %{conn: conn} do
    {conn, page} = publishing_page(conn)
    existing_follow(page)

    html =
      conn
      |> Phoenix.ConnTest.recycle()
      |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
      |> get(~p"/organizations/#{page.slug}/following")
      |> html_response(200)

    assert html =~ "Konten auf anderen Netzwerken"
    assert html =~ "Angefragt"

    # The merge filled the address label from "Fediverse-Aliase" (aliases) and
    # the empty line from the members one; both are named so they cannot return.
    refute html =~ "Fediverse-Aliase"
  end
end

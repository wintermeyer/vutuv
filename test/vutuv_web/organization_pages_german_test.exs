defmodule VutuvWeb.OrganizationPagesGermanTest do
  @moduledoc """
  The German rendering of the page-side surfaces (issue #1336). vutuv is a
  German site, and `Phoenix.ConnTest` defaults to English, so a fuzzy-filled
  translation ships confident nonsense while every other test stays green.

  This is not hypothetical here. `mix gettext.extract --merge` filled these very
  strings from unrelated ones: "This page does not follow anyone yet." came back
  as **"Diese Seite gibt es nicht"** (this page does not exist), and
  "Members and organizations" as "Organisation hinzufügen" (add organization).
  Both were flagged `fuzzy` — but as `#, elixir-autogen, elixir-format, fuzzy`,
  which the obvious `grep "#, fuzzy"` does not match.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  # `recycle/1` first: these conns have already served a response (the login
  # POST, the act-as POST), and a header cannot be set on a sent conn.
  defp german(conn) do
    conn |> Phoenix.ConnTest.recycle() |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
  end

  test "the Follows page reads as German about the page, not the reader", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

    html =
      conn
      |> german()
      |> get(~p"/organizations/#{organization.slug}/following")
      |> html_response(200)

    assert html =~ "Mitglieder und Organisationen"
    assert html =~ "Diese Seite folgt noch niemandem."
    assert html =~ "Themen"

    # The two the merge got wrong, named so the mistake cannot come back.
    refute html =~ "Diese Seite gibt es nicht"
    refute html =~ "Organisation hinzufügen"

    # "Folge ich" is the member-voiced translation of "Following" — the wrong
    # voice under a page's nav, which is why the tab has its own msgid.
    refute html =~ "Folge ich"
  end

  test "the feed page explains itself in German", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

    html =
      conn
      |> german()
      |> get(~p"/organizations/#{organization.slug}/feed")
      |> html_response(200)

    assert html =~ "Noch nichts da."
    assert html =~ "aus dem eigenen Konto"
  end

  test "the remote-follower list reads as German", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)

    organization =
      owner
      |> active_organization_for()
      |> Ecto.Changeset.change(%{username: "acme", fediverse_followers?: true})
      |> Repo.update!()

    {:ok, _} =
      Vutuv.Fediverse.add_organization_follower(organization, %{
        actor_uri: "https://remote.example/users/frida",
        inbox_uri: "https://remote.example/users/frida/inbox",
        handle: "@frida@remote.example",
        name: "Frida Fern"
      })

    html =
      conn
      |> german()
      |> get(~p"/organizations/#{organization.slug}/fediverse/followers")
      |> html_response(200)

    assert html =~ "Follower aus anderen Netzwerken"
    assert html =~ "Zurück zur Fediverse-Seite"
    assert html =~ "Nach außen veröffentlicht die Seite die Anzahl, nie die Namen."

    # What the merge filled these two with: a link back to the start page, and a
    # sentence about the READER's own vutuv posts on a page's list.
    refute html =~ "Zur Startseite"
    refute html =~ "Ihren vutuv-Beiträgen"
  end

  test "the Fediverse card offers the list in German", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)

    organization =
      owner
      |> active_organization_for()
      |> Ecto.Changeset.change(%{username: "acme", fediverse_followers?: true})
      |> Repo.update!()

    {:ok, _} =
      Vutuv.Fediverse.add_organization_follower(organization, %{
        actor_uri: "https://remote.example/users/frida",
        inbox_uri: "https://remote.example/users/frida/inbox",
        handle: "@frida@remote.example",
        name: "Frida Fern"
      })

    html =
      conn
      |> german()
      |> get(~p"/organizations/#{organization.slug}/fediverse")
      |> html_response(200)

    assert html =~ "Wer dieser Seite folgt"
    # The merge made this link a sentence about somebody following the page.
    refute html =~ "folgt dieser Seite."
  end

  test "the follow-as-page pill names the page in German", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    conn = post(conn, ~p"/organizations/#{organization.slug}/act_as")

    member = insert(:activated_user)
    html = conn |> german() |> get(~p"/#{member}") |> html_response(200)

    assert html =~ "Als #{organization.name} folgen"
    # The merge rendered this as "Follower von …", a label rather than an action.
    refute html =~ "Follower von #{organization.name}"
  end
end

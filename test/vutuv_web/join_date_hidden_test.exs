defmodule VutuvWeb.JoinDateHiddenTest do
  @moduledoc """
  Nothing a reader, an agent or another server sees says how long somebody has
  been a member (Stefan, 2026-09-18). The date itself stays in the database —
  the onboarding window, the sweepers and the admin views read it — only its
  display is gone, so this module pins every public surface that used to show
  it: the profile page, its share card, its agent formats, its schema.org
  block, its fediverse actor and the Mastodon API's account entity.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse
  alias VutuvWeb.Fediverse.Docs
  alias VutuvWeb.OgImageController

  @joined ~N[2008-02-15 10:00:00]

  setup do
    %{member: insert_activated_user(inserted_at: @joined)}
  end

  test "the profile page, in English and in German", %{conn: conn, member: member} do
    html = conn |> get(~p"/#{member}") |> html_response(200)
    refute html =~ "Member since"

    de_html =
      build_conn()
      |> put_req_header("accept-language", "de-DE,de")
      |> get(~p"/#{member}")
      |> html_response(200)

    refute de_html =~ "Mitglied seit"
  end

  test "the share card says followers and nothing about the join year", %{member: member} do
    follow!(insert(:activated_user), member)

    meta = OgImageController.profile_card_data(member).meta

    assert meta =~ "1"
    refute meta =~ "2008"
  end

  test "no agent format carries the join date", %{conn: conn, member: member} do
    for ext <- ~w(md txt json xml), lang <- ~w(en de) do
      body = conn |> get("/#{member.username}.#{ext}?lang=#{lang}") |> response(200)

      refute body =~ "2008-02-15", "/#{member.username}.#{ext}?lang=#{lang} states the join date"
      refute body =~ "member_since"
      refute body =~ "Member since"
      refute body =~ "Mitglied seit"
    end
  end

  test "the page's schema.org block has no creation date", %{conn: conn, member: member} do
    page = conn |> get(~p"/#{member}") |> html_response(200) |> json_ld("ProfilePage")

    assert page, "the profile still describes itself as a ProfilePage"
    refute Map.has_key?(page, "dateCreated")
  end

  test "the fediverse actor has no published date", %{member: member} do
    {:ok, actor} = Fediverse.ensure_actor(member)

    refute Map.has_key?(Docs.actor(member, actor), "published"),
           "Mastodon shows an actor's `published` as the date the account joined."
  end

  test "a Mastodon app is told 1 April 1970 for every member", %{conn: conn, member: member} do
    account =
      conn
      |> on_mastodon_host()
      |> get("/api/v1/accounts/lookup", %{"acct" => member.username})
      |> json_response(200)

    assert account["created_at"] == "1970-04-01T00:00:00.000Z",
           "`created_at` is required and apps show it as the join date, so every " <>
             "member gets the same placeholder in Mastodon's own shape."
  end
end

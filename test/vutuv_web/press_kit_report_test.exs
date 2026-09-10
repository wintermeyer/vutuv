defmodule VutuvWeb.PressKitReportTest do
  @moduledoc """
  The Report control on the press surfaces (issue #2089), which is the one act a
  press kit has to offer to somebody who has **no account here**: a picture
  published for redistribution is the likeliest of all of them to draw a rights
  holder's complaint.

  What the tests below hold:

    * the section page and the lightbox carry a quiet Report on every picture a
      reader can actually see, and none on a held one — a stand-in is not a
      picture anybody can recognise their work in;
    * a signed-in member is sent to the in-app form and a signed-out reader to
      the public notice form with the picture's own address already in it;
    * the kit's own team is offered none — they remove a picture from the
      editor rather than report it;
    * the in-app form for a press picture renders (it raised `BadMapError`
      until this issue: `Vutuv.Images.preview_url/1` indexed the profile-column
      map by kind), names which picture it is, and offers `spam` — the one
      picture that can itself be an advertisement;
    * the German page says the German words, which is what a `.po` fuzzy-fill
      would otherwise ship as confident nonsense.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.ImageHelpers, only: [put_press_picture: 1, put_press_picture: 2]

  alias Vutuv.PressKit

  setup do
    owner = insert_activated_user(username: "presse.person", first_name: "Ada", last_name: "King")
    {:ok, owner: owner}
  end

  # The owner's own view of their kit, which is the one that must offer no
  # Report at all.
  defp as_owner(conn) do
    {conn, owner} = create_and_login_user(conn)
    {conn, owner}
  end

  defp de(conn), do: put_req_header(conn, "accept-language", "de-DE,de;q=0.9")

  describe "the section page" do
    test "offers a signed-out reader the public notice form, filled in", %{
      conn: conn,
      owner: owner
    } do
      image = put_press_picture(owner)

      html = conn |> get(~p"/#{owner}/press") |> html_response(200)

      assert html =~ "data-press-report"
      assert html =~ "/system/report?url="
      # The picture's own address, not the page's: a notice has to name the
      # picture the freeze will take offline.
      assert html =~ URI.encode_www_form(VutuvWeb.Endpoint.url() <> PressKit.url(image, "large"))
    end

    test "sends a signed-in member to the in-app form", %{conn: conn, owner: owner} do
      image = put_press_picture(owner)
      {conn, _reader} = create_and_login_user(conn)

      html = conn |> get(~p"/#{owner}/press") |> html_response(200)

      assert html =~ "/reports/new?"
      assert html =~ "id=#{image.id}"
      refute html =~ "/system/report?url="
    end

    test "offers the owner nothing to report", %{conn: conn} do
      {conn, owner} = as_owner(conn)
      put_press_picture(owner)

      html = conn |> get(~p"/#{owner}/press") |> html_response(200)

      refute html =~ "data-press-report"
    end

    test "offers nothing on a picture the AI gate is still holding", %{conn: conn, owner: owner} do
      put_press_picture(owner, moderation: "pending")

      html = conn |> get(~p"/#{owner}/press") |> html_response(200)

      refute html =~ "data-press-report"
    end

    test "a logo variant carries it too", %{conn: conn, owner: owner} do
      put_press_picture(owner, logo: true, alt: "Wortmarke, hell")

      html = conn |> get(~p"/#{owner}/press") |> html_response(200)

      assert html =~ "data-press-report"
    end

    test "the lightbox is told where to report the photo", %{conn: conn, owner: owner} do
      put_press_picture(owner)

      html = conn |> get(~p"/#{owner}/press") |> html_response(200)

      assert html =~ "data-photo-report"
      assert html =~ "data-label-report"
    end

    test "says it in German", %{conn: conn, owner: owner} do
      put_press_picture(owner)

      html = conn |> de() |> get(~p"/#{owner}/press") |> html_response(200)

      assert html =~ "Dieses Bild melden"
    end
  end

  describe "the in-app report form" do
    test "renders for a press photo, with the picture and the spam category", %{
      conn: conn,
      owner: owner
    } do
      image = put_press_picture(owner, alt: "Am Schreibtisch")
      {conn, _reader} = create_and_login_user(conn)

      html =
        conn
        |> get(~p"/reports/new?#{[type: "image", id: image.id]}")
        |> html_response(200)

      assert html =~ "Press photo"
      assert html =~ "Am Schreibtisch"
      assert html =~ PressKit.url(image, "large")
      # A press section is where a picture can itself be an advertisement; a
      # profile picture deliberately offers no such category.
      assert html =~ ~s(value="spam")
      assert html =~ ~s(value="copyright")
    end

    test "names a logo variant as one, in German", %{conn: conn, owner: owner} do
      image = put_press_picture(owner, logo: true, alt: "Wortmarke, dunkel")
      {conn, _reader} = create_and_login_user(conn)

      html =
        conn
        # The login already sent a response on this conn, and a header cannot be
        # put on a sent one.
        |> recycle()
        |> de()
        |> get(~p"/reports/new?#{[type: "image", id: image.id]}")
        |> html_response(200)

      assert html =~ "Logo-Variante"
      assert html =~ "Wortmarke, dunkel"
    end
  end

  describe "the public notice form" do
    test "prefills the pasted address from the link", %{conn: conn} do
      url = "https://vutuv.de/system/press_kit/abc/large.avif"

      html = conn |> get(~p"/system/report?#{[url: url]}") |> html_response(200)

      assert html =~ url
    end
  end
end

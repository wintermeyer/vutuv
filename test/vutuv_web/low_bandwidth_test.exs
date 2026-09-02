defmodule VutuvWeb.LowBandwidthTest do
  @moduledoc """
  Data-saving mode end to end: the box on the sign-up form, its own page under
  /settings, and the two things the mode is for — a composer that never
  fetches the 155 kB WYSIWYG editor, and pictures that load as their lite
  version with an HD control to fetch the full one.

  `VutuvWeb.MarkdownEditorTest` covers what the editor component renders
  either way, and the uploader tests cover which files exist. What is asserted
  here is the wiring around them: that the answer survives the round trip from
  a sign-up form into the column, that "did not tick the box" stays
  distinguishable from "chose off", and that a real page really does come back
  without the bundle's URL and with the lite pictures — and, for everybody
  else, exactly as before.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Posts
  alias Vutuv.Prefs

  describe "the sign-up form" do
    test "offers the box, unticked", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      assert body =~ "user[low_bandwidth?]"
      assert body =~ Prefs.label(:low_bandwidth?)
      # Off by default: the editor is what most people expect from a composer,
      # and a first-time visitor cannot judge this trade for themselves.
      refute checkbox_checked?(body, "user[low_bandwidth?]")
    end

    test "the explanation says what the switch actually does", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      # The member is being asked to give something up, so the box has to name
      # what changes (pictures, the editor), the way back per picture, and
      # that the whole thing is theirs to switch off.
      assert body =~ "stronger compression"
      assert body =~ "richer editor"
      assert body =~ "full quality with one tap"
      assert body =~ "switch the mode off at any time"
    end

    # vutuv is a German site, and a one-word label is both the likeliest thing
    # `gettext.extract --merge` fuzzy-fills with something unrelated and the
    # least likely to be noticed. Assert the German by name.
    test "the box is German for a German visitor", %{conn: conn} do
      body =
        conn
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> get(~p"/")
        |> html_response(200)

      assert body =~ "Datensparmodus"
      assert body =~ "Bandbreite"
      assert body =~ "stärker komprimiert"
      assert body =~ "jederzeit abschaltbar"
      # The English must not leak through beside it.
      refute body =~ "Low-bandwidth mode"
      # And not the social sense of "Connection", which is what the obvious
      # msgid would have rendered here.
      refute body =~ "Vernetzung"
    end

    test "ticking it is stored as a choice", %{conn: conn} do
      attrs = low_bandwidth_attrs("lowbw-on", "true")
      post(conn, ~p"/new_registration", user: attrs)

      assert registered(attrs).low_bandwidth?
    end

    # The subtle one, and the reason `drop_untouched_low_bandwidth/1` exists.
    # A checkbox posts its hidden "false" for the box nobody touched. Storing
    # that would write indifference into the column as a decision and cut the
    # member off from the installation default for good — on exactly the kind
    # of installation this switch is for, where an admin turns it on for
    # everybody at /admin/preferences.
    test "walking past it leaves the column NULL, so it still inherits", %{conn: conn} do
      attrs = low_bandwidth_attrs("lowbw-off", "false")
      post(conn, ~p"/new_registration", user: attrs)

      user = registered(attrs)
      assert is_nil(user.low_bandwidth?)
      # NULL is what inherits: an installation that turns the default on at
      # /admin/preferences reaches this member, an explicit false never would.
      # (`Vutuv.PrefsTest` owns the inheritance mechanism itself - it injects
      # installation defaults into a node-global cache and is sync for it.)
      refute Prefs.get(user, :low_bandwidth?)
    end

    test "a form that carries no box at all is the same as not ticking it", %{conn: conn} do
      attrs = registration_attrs("lowbw-absent")
      post(conn, ~p"/new_registration", user: attrs)

      assert is_nil(registered(attrs).low_bandwidth?)
    end
  end

  describe "/settings/bandwidth" do
    test "has a row on the hub, and shows the card and saves the switch", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      hub = conn |> get(~p"/settings") |> html_response(200)
      assert hub =~ ~s(href="/settings/bandwidth")

      body = conn |> get(~p"/settings/bandwidth") |> html_response(200)
      assert body =~ "Bandwidth"
      assert body =~ Prefs.label(:low_bandwidth?)
      refute checkbox_checked?(body, "user[low_bandwidth?]")
      # The form posts where the controller listens (the rendered action=,
      # never a route this test knows exists).
      assert body =~ ~s(action="/settings/low_bandwidth")

      conn = put(conn, ~p"/settings/low_bandwidth", user: %{"low_bandwidth?" => "true"})
      assert redirected_to(conn) == ~p"/settings/bandwidth"
      assert Accounts.get_user(user.id).low_bandwidth?
    end

    # Unticking HERE is a real choice, unlike walking past the sign-up box, so
    # it is stored as one — and the reset link is the way back to inheriting.
    test "unticking is stored as an explicit no, and reset restores inheriting", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      put(conn, ~p"/settings/low_bandwidth", user: %{"low_bandwidth?" => "true"})
      put(conn, ~p"/settings/low_bandwidth", user: %{"low_bandwidth?" => "false"})
      assert Accounts.get_user(user.id).low_bandwidth? == false

      # An explicit "false" is what the reset link is offered for.
      body = conn |> get(~p"/settings/bandwidth") |> html_response(200)
      assert body =~ "reset-low-bandwidth"

      conn = post(conn, ~p"/settings/low_bandwidth/reset")
      assert redirected_to(conn) == ~p"/settings/bandwidth"
      assert is_nil(Accounts.get_user(user.id).low_bandwidth?)
    end

    # The cookie a reverse proxy routes on (`Vutuv.LowBandwidth.cookie_name/0`)
    # follows the preference on the next page request, both ways.
    test "a page request keeps the proxy cookie in step with the switch", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      refute conn |> get(~p"/settings/bandwidth") |> low_bandwidth_cookie()

      set_low_bandwidth(user, true)
      assert conn |> get(~p"/settings/bandwidth") |> low_bandwidth_cookie() =~ "=1"
    end
  end

  describe "the composer a low-bandwidth member gets" do
    # The end-to-end version of the promise. A component test can only say
    # what the component rendered; this says what actually came back over the
    # wire for a real member on a real page.
    test "/feed comes back without the editor bundle anywhere in it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, _view, html} = live(conn, ~p"/feed")
      assert html =~ "markdown_editor.js"

      set_low_bandwidth(user, true)
      {:ok, _view, html} = live(conn, ~p"/feed")
      refute html =~ "markdown_editor.js"
      refute html =~ "data-mde-src"

      # Still a composer: the plain Markdown field is right there.
      assert html =~ "data-mde-source"
      assert html =~ ~s(name="post[body]")
    end

    # The message composer only exists once a conversation is open - without
    # one the page carries no editor at all, and the refute below would pass
    # for the wrong reason.
    test "the messages page too", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conversation = insert_conversation_between(user, insert(:user))

      {:ok, _view, html} = live(conn, ~p"/messages/#{conversation.id}")
      assert html =~ "data-mde-source"
      assert html =~ "markdown_editor.js"

      set_low_bandwidth(user, true)
      {:ok, _view, html} = live(conn, ~p"/messages/#{conversation.id}")
      assert html =~ "data-mde-source"
      refute html =~ "markdown_editor.js"
    end
  end

  describe "the pictures a low-bandwidth member gets" do
    # The lite version in the slot, the full one a tap away — and for everybody
    # else not a byte of it: no wrapper, no control, the URL the page always had.
    test "a post photo in the feed loads as its lite version with an HD control", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      image = insert(:post_image, user: user, post: nil, token: "litegal")
      {:ok, _} = Posts.create_post(user, %{body: "A picture.", image_ids: [image.id]})

      {:ok, _view, html} = live(conn, ~p"/feed")
      assert html =~ ~s(src="/post_images/litegal/feed.avif")
      refute html =~ "/post_images/litegal/lite.avif"
      refute html =~ "data-hd-load"
      refute html =~ "data-lite-picture"

      # The mode alone changes nothing while no lite file exists: the URL is
      # only ever named for a file that is there.
      set_low_bandwidth(user, true)
      {:ok, _view, html} = live(conn, ~p"/feed")
      assert html =~ ~s(src="/post_images/litegal/feed.avif")
      refute html =~ "data-hd-load"

      write_lite_file!("litegal")
      {:ok, _view, html} = live(conn, ~p"/feed")
      assert html =~ ~s(src="/post_images/litegal/lite.avif")
      assert html =~ ~s(data-hd="/post_images/litegal/feed.avif")
      assert html =~ "data-hd-load"
      assert html =~ "Load this picture in full quality"
    end

    # The lightbox is the one place the member explicitly asks for the big
    # picture, and even there 1600 px is more than the phone they most likely
    # hold can show.
    test "the lightbox opens the 1600 px photo instead of the 2560 px one", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      image = insert(:post_image, user: user, post: nil, token: "litebox")
      {:ok, post} = Posts.create_post(user, %{body: "A picture.", image_ids: [image.id]})

      html = conn |> get(Posts.path(post)) |> html_response(200)
      assert html =~ ~s(data-photo-src="/post_images/litebox/xl.avif")

      set_low_bandwidth(user, true)
      html = conn |> get(Posts.path(post)) |> html_response(200)
      assert html =~ ~s(data-photo-src="/post_images/litebox/large.avif")
      refute html =~ "/post_images/litebox/xl.avif"
    end
  end

  defp low_bandwidth_attrs(prefix, value) do
    prefix |> registration_attrs() |> Map.put("low_bandwidth?", value)
  end

  defp set_low_bandwidth(user, value) do
    user
    |> Ecto.Changeset.change(%{low_bandwidth?: value})
    |> Repo.update!()
  end

  # The lite file a regeneration or upload would have written; the token is
  # this test's own, so the directory is nobody else's.
  defp write_lite_file!(token) do
    dir = Vutuv.Uploads.disk_dir("post_images/#{token}")
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(4, 4, color: [1, 2, 3])
    {:ok, _} = Image.write(img, Path.join(dir, "lite.avif"))
    on_exit(fn -> File.rm_rf(dir) end)
  end

  defp low_bandwidth_cookie(conn) do
    conn
    |> get_resp_header("set-cookie")
    |> Enum.find(&String.starts_with?(&1, Vutuv.LowBandwidth.cookie_name() <> "="))
  end

  defp registered(%{"emails" => %{"0" => %{"value" => email}}}) do
    Repo.one!(from(u in User, join: e in assoc(u, :emails), where: e.value == ^email))
  end
end

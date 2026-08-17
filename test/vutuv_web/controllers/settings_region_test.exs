defmodule VutuvWeb.SettingsRegionTest do
  @moduledoc """
  The member-facing half of issue #1502: a new account takes its date shape and
  time zone from the browser, /settings/preferences is where either is
  overridden, and every page then writes its stamps that way.

  Locale is a test dimension here, not decoration: a German request and an
  English one must differ in their *words* and agree on their *digits* whenever
  the reader's region is the same.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias VutuvWeb.Plug.Locale

  describe "sign-up" do
    test "stamps the browser's time zone and the header's date region", %{conn: conn} do
      attrs = registration_attrs("clock")

      {:ok, user} =
        conn
        |> put_req_header("accept-language", "en-US,en;q=0.9")
        |> Locale.call([])
        |> Accounts.register_user(Map.put(attrs, "time_zone", "America/Denver"))

      assert user.date_region == "US"
      assert user.time_zone == "America/Denver"
    end

    # Both values come from places the member cannot see, so neither may be able
    # to fail a sign-up: a browser reporting a zone this installation's tzdata
    # does not carry must leave the field inheriting, not raise an error beside
    # a field that is not on the screen.
    test "an unknown zone is dropped rather than refused", %{conn: conn} do
      attrs = registration_attrs("clock")

      {:ok, user} =
        conn
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> Locale.call([])
        |> Accounts.register_user(Map.put(attrs, "time_zone", "Middle/Earth"))

      assert user.time_zone == nil
      assert user.date_region == "DE"
    end

    test "a hand-crafted POST cannot set the date region itself", %{conn: conn} do
      attrs = registration_attrs("clock")

      {:ok, user} =
        conn
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> Locale.call([])
        |> Accounts.register_user(Map.put(attrs, "date_region", "US"))

      assert user.date_region == "DE"
    end

    test "the form carries the hidden field app.js fills", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(name="user[time_zone]")
      assert html =~ "data-timezone-field"
    end
  end

  describe "the settings form" do
    test "offers both knobs, the shapes worked out as samples", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings/preferences") |> html_response(200)

      assert html =~ ~s(id="user_date_region")
      assert html =~ ~s(id="user_time_zone")
      assert html =~ "31.12.2026, 14:30"
      assert html =~ "12/31/2026, 2:30 PM"
      assert html =~ "Europe/Berlin"
      assert html =~ "data-browser-timezone"
    end

    # Named assertions, because `gettext.extract --merge` fuzzy-fills a new
    # msgid with the translation of some string it merely looks similar to, and
    # nothing else fails the build when it does.
    test "the German labels are German", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/settings/preferences")
        |> html_response(200)

      assert html =~ "Datumsformat"
      assert html =~ "Zeitzone"
      assert html =~ "Deutschland, Österreich, Schweiz"
      assert html =~ "Vereinigte Staaten"
      assert html =~ "Ihr Browser meldet:"
    end

    test "saves a region and a zone", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        put(conn, ~p"/settings/language",
          user: %{"locale" => "en", "date_region" => "US", "time_zone" => "America/New_York"}
        )

      assert redirected_to(conn) == ~p"/settings/preferences"

      saved = Repo.get!(User, user.id)
      assert saved.date_region == "US"
      assert saved.time_zone == "America/New_York"
    end

    test "refuses a zone the time zone database does not know", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = put(conn, ~p"/settings/language", user: %{"time_zone" => "Middle/Earth"})

      assert html_response(conn, 422) =~ "user_time_zone"
      assert Repo.get!(User, user.id).time_zone == nil
    end

    test "refuses a date region outside the offered set", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = put(conn, ~p"/settings/language", user: %{"date_region" => "XX"})

      assert html_response(conn, 422)
      assert Repo.get!(User, user.id).date_region == nil
    end

    test "the reset link appears only once something is set, and clears both", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      refute conn |> get(~p"/settings/preferences") |> html_response(200) =~ ~s(id="reset-region")

      put(conn, ~p"/settings/language", user: %{"date_region" => "US", "time_zone" => "UTC"})
      assert conn |> get(~p"/settings/preferences") |> html_response(200) =~ ~s(id="reset-region")

      conn = post(conn, ~p"/settings/region/reset")
      assert redirected_to(conn) == ~p"/settings/preferences"

      saved = Repo.get!(User, user.id)
      assert saved.date_region == nil
      assert saved.time_zone == nil
    end

    # The form must not state a shape the rest of the site contradicts: an
    # untouched member reads their browser's guess everywhere else, so the
    # select has to show that, not the installation default.
    test "an untouched member sees the shape their browser gets them", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "en-US,en;q=0.9")
        |> get(~p"/settings/preferences")
        |> html_response(200)

      assert html =~ ~s(<option selected value="US">)
    end
  end

  describe "rendered timestamps" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Vutuv.Posts.create_post(user, %{"body" => "Zeitstempel"})

      # A post from a day the "today"/"yesterday" wording can never claim, so
      # the stamp under test is always the full date form.
      post =
        post
        |> Ecto.Changeset.change(%{inserted_at: ~N[2020-01-15 10:00:00]})
        |> Repo.update!()

      %{conn: conn, user: user, post: post}
    end

    test "a member's own zone and region reach the post permalink", ctx do
      {:ok, _user} =
        Accounts.update_user(ctx.user, %{"date_region" => "US", "time_zone" => "America/Chicago"})

      html =
        ctx.conn
        |> get(Vutuv.Posts.path(ctx.post))
        |> html_response(200)

      # 2020-01-15 10:00 UTC is 04:00 in Chicago, in the US shape.
      assert html =~ "1/15/20, 4:00 AM"
    end

    test "the words follow the language while the digits follow the region", ctx do
      {:ok, _user} =
        Accounts.update_user(ctx.user, %{"date_region" => "ISO", "time_zone" => "Asia/Tokyo"})

      html =
        ctx.conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(Vutuv.Posts.path(ctx.post))
        |> html_response(200)

      assert html =~ "2020-01-15, 19:00"
    end
  end
end

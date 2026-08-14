defmodule VutuvWeb.GravatarButtonTest do
  @moduledoc """
  The member's own gravatar.com lookup on /settings/profile (issue #1447).

  The load-bearing test here is the last one: **registration must contact
  gravatar.com never**. That lookup used to run in a background task for every
  sign-up, which handed a US service the fact that an address had just joined
  vutuv — a third-party transfer nobody asked for, and one the privacy page
  promised did not happen. So the stub records any hit and the test waits for
  one that must not come.

  Not async: flips `:fetch_gravatar` and `:gravatar_req_options`, both global
  and not rolled back by the SQL sandbox. `:fetch_gravatar` is read by
  `Accounts.gravatar_import_available?/1` and the profile template; it is
  `false` for the rest of the suite (config/test.exs).
  """
  use VutuvWeb.ConnCase, async: false

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_gravbtn_#{System.unique_integer([:positive])}")

    saved =
      for k <- [:uploads_dir_prefix, :gravatar_req_options, :fetch_gravatar],
          do: {k, Application.fetch_env(:vutuv, k)}

    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)
    Application.put_env(:vutuv, :fetch_gravatar, true)

    on_exit(fn ->
      File.rm_rf(tmp)

      for {k, was} <- saved do
        case was do
          {:ok, value} -> Application.put_env(:vutuv, k, value)
          :error -> Application.delete_env(:vutuv, k)
        end
      end
    end)

    :ok
  end

  describe "the button on /settings/profile" do
    test "renders, and posts to the route it actually names", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      body = conn |> get(~p"/settings/profile") |> html_response(200)

      assert body =~ "gravatar.com"
      assert body =~ ~s(id="import-gravatar")
      # The button is wired to the separate form by `form=`, since a form cannot
      # nest inside the profile form.
      assert body =~ ~s(form="gravatar-form")
      # Assert the form's rendered action rather than a route we know exists:
      # a Save button pointing at a retired URL is exactly how /settings/privacy
      # 404ed in production for eight releases.
      assert body =~ ~s(action="/settings/profile/gravatar")
    end

    # The German render is the one real visitors get; an English-only assertion
    # would pass even if the msgstr were empty or fuzzy-filled with nonsense.
    test "says it in German for a German browser", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      body =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/settings/profile")
        |> html_response(200)

      assert body =~ "Mein Bild von gravatar.com holen"
      # The sentence must keep saying what is sent, in German too.
      assert body =~ "Hashwert der Adresse"
    end

    # An air-gapped intranet installation cannot reach gravatar.com, so it must
    # not be offered a button that can only ever fail.
    test "is absent when the installation has the lookup switched off", %{conn: conn} do
      Application.put_env(:vutuv, :fetch_gravatar, false)
      {conn, _user} = create_and_login_user(conn)

      body = conn |> get(~p"/settings/profile") |> html_response(200)

      refute body =~ ~s(id="import-gravatar")
      refute body =~ "gravatar.com"
    end
  end

  describe "pressing it" do
    test "stores the picture and says so", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      stub_gravatar(200, png_bytes(), "image/png")

      conn = post(conn, ~p"/settings/profile/gravatar")

      assert redirected_to(conn) == "/settings/profile#avatar"
      assert flash_text(conn, :info) =~ "gravatar.com"
      assert Repo.reload!(user).avatar == "#{user.username}.png"
    end

    # The two failures must read differently — "there is no picture for you"
    # is not "we could not ask".
    test "says so when gravatar.com has nothing for the address", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      stub_gravatar(404, "", "text/plain")

      conn = post(conn, ~p"/settings/profile/gravatar")

      assert flash_text(conn, :error) =~ "no picture"
      assert Repo.reload!(user).avatar == nil
    end

    test "says something different when gravatar.com cannot be reached", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      stub_gravatar(500, "", "text/plain")

      conn = post(conn, ~p"/settings/profile/gravatar")

      assert flash_text(conn, :error) =~ "could not be reached"
      assert Repo.reload!(user).avatar == nil
    end

    # The settings pipeline bounces an anonymous request to the start page
    # (RequireLogin's convention), so nothing reaches gravatar.com.
    test "a logged-out visitor cannot fire it", %{conn: conn} do
      test_pid = self()

      Application.put_env(:vutuv, :gravatar_req_options,
        plug: fn c ->
          send(test_pid, :gravatar_was_called)
          Plug.Conn.send_resp(c, 200, "")
        end
      )

      conn = post(conn, ~p"/settings/profile/gravatar")

      assert redirected_to(conn) == "/"
      refute_receive :gravatar_was_called, 200
    end
  end

  # The whole point of issue #1447's second round: signing up talks to nobody.
  test "registration never contacts gravatar.com", %{conn: conn} do
    test_pid = self()

    Application.put_env(:vutuv, :gravatar_req_options,
      plug: fn c ->
        send(test_pid, :gravatar_was_called)
        Plug.Conn.send_resp(c, 200, "")
      end
    )

    {_conn, user} = create_and_login_user(conn)

    # refute_receive, not a bare assertion: the old code ran the fetch in a
    # Task.Supervisor child, so a re-added background call would arrive late
    # and a synchronous check would miss it.
    refute_receive :gravatar_was_called, 500
    assert Repo.reload!(user).avatar == nil
  end

  defp stub_gravatar(status, body, content_type) do
    Application.put_env(:vutuv, :gravatar_req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type(content_type)
        |> Plug.Conn.send_resp(status, body)
      end
    )
  end

  defp png_bytes do
    {:ok, img} = Image.new(120, 120, color: [10, 120, 200])
    path = Path.join(System.tmp_dir!(), "gravbtn_#{System.unique_integer([:positive])}.png")
    {:ok, _} = Image.write(img, path)
    File.read!(path)
  end

  defp flash_text(conn, key), do: Phoenix.Flash.get(conn.assigns.flash, key) || ""
end

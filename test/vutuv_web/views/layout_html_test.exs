defmodule VutuvWeb.LayoutHTMLTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.BuildInfo
  alias VutuvWeb.LayoutHTML

  test "shell_session avatar initials come from first+last, not the honorific title", %{conn: _} do
    # Regression: a member with a Titel ("Dr.") saw the shell top-bar monogram
    # read "DA" (first letters of "Dr." + "Anna") while every other avatar in the
    # app showed "AS". The shell must build its initials from the same first+last
    # basis as <.avatar>, so the two always agree.
    user = insert(:user, first_name: "Anna", last_name: "Schmidt", honorific_prefix: "Dr.")

    session = LayoutHTML.shell_session(%{current_user: user})

    assert session["user_name"] == "Dr. Anna Schmidt"
    assert session["user_initials"] == "AS"
  end

  test "the app layout wraps page content with the shared shell nav and footer", %{conn: conn} do
    conn = get(conn, ~p"/impressum")
    body = html_response(conn, 200)

    # The nav chrome is the embedded ShellLive (top bar + mobile tab bar).
    assert body =~ "id=\"app-shell\""
    assert body =~ ~p"/datenschutzerklaerung"
    assert footer_html(body) =~ ~p"/nutzungsbedingungen"
  end

  test "the footer links to the current GitHub repo and its issue tracker", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)

    assert body =~ "https://github.com/wintermeyer/vutuv"
    assert body =~ "https://github.com/wintermeyer/vutuv/issues/new"
    refute body =~ "github.com/vutuv/vutuv"
  end

  # The developer documentation is only useful if people can find it: the
  # shared footer must link it from every page, logged out and logged in.
  test "the footer links the developer documentation everywhere", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)
    assert footer_html(body) =~ ~s|href="/developers"|

    {conn, _user} = create_and_login_user(conn)
    body = conn |> get(~p"/access_tokens") |> html_response(200)
    assert footer_html(body) =~ ~s|href="/developers"|
  end

  # 2016, not 2019: the oldest account on vutuv.de dates from 2016-11-20, and
  # 2,615 members had joined before 2017. The media kit's "Founded" fact says
  # the same year.
  test "the footer copyright spans from 2016 to the current year", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)

    assert body =~ "© 2016 - #{Date.utc_today().year}"
  end

  test "the footer links to wintermeyer-consulting.de without the www host", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)

    assert body =~ "https://wintermeyer-consulting.de"
    refute body =~ "www.wintermeyer-consulting.de"
  end

  test "the footer is shown on mobile, not hidden behind a breakpoint", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)
    footer = footer_html(body)

    # It used to be `hidden md:block` (mobile-hidden). The <footer> element itself
    # must no longer be gated behind a breakpoint, so it renders on mobile too.
    # Scope this to the opening tag's classes (inner content may use `hidden` for
    # unrelated reasons).
    [footer_tag] = Regex.run(~r/<footer[^>]*>/, footer)
    refute footer_tag =~ "hidden"
    # Two columns on a phone, four from md up - never four on a phone.
    assert footer =~ "grid-cols-2"
    assert footer =~ "md:grid-cols-4"
  end

  test "the footer nav groups its links under headings", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)
    [nav] = Regex.run(~r{<nav.*?</nav>}s, footer_html(body))

    # It was one flat row of middot-separated links, which had grown to ten
    # entries with nothing saying where the next one belonged. Four headed
    # groups, each an actual list, so a link has a home and a thumb has a row
    # to hit rather than a word inside a paragraph.
    for heading <- ["Network", "Developers", "Company", "Legal"] do
      assert nav =~ ">#{heading}</h2>"
    end

    assert length(Regex.scan(~r{<ul[^>]*>}, nav)) == 4
    refute nav =~ "·"
  end

  # The keyboard-shortcuts help overlay lives in the shared layout so "?" and
  # the account-menu item can open it from any page. It ships hidden.
  test "the layout carries the keyboard-shortcuts help overlay", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)

    assert body =~ ~s(id="shortcuts-overlay")
    assert body =~ ~s(role="dialog")
    assert body =~ "Keyboard shortcuts"
    # The overlay opens via JS; it must start hidden.
    [overlay_tag] = Regex.run(~r/<div[^>]*id="shortcuts-overlay"[^>]*>/, body)
    assert overlay_tag =~ "hidden"
  end

  # Cmd/Ctrl+Enter submits the post and message composers (issue #1196); the
  # overlay is where a member can discover that, so the row must not get lost.
  test "the shortcuts overlay lists the Cmd/Ctrl+Enter send shortcut", %{conn: conn} do
    body = conn |> get(~p"/impressum") |> html_response(200)

    assert body =~ "⌘/Ctrl"
    assert body =~ "Send the post or message you are writing"
  end

  # The German render must carry the hand-written translations, not English or
  # a fuzzy-merge artifact (the gettext merge hazard in CLAUDE.md).
  test "the shortcuts overlay is translated for German visitors", %{conn: conn} do
    body =
      conn
      |> put_req_header("accept-language", "de-DE,de")
      |> get(~p"/impressum")
      |> html_response(200)

    assert body =~ "Beitrag oder Nachricht absenden, während Sie schreiben"
    assert body =~ "Die Einzeltasten-Kürzel pausieren, während Sie tippen"
  end

  # There is no version number any more: the credit bar names the commit the
  # site runs (linked in the configured source repository) and dates it.
  test "the credit bar links the running commit and dates it, in German", %{conn: conn} do
    footer =
      conn
      |> put_req_header("accept-language", "de-DE,de")
      |> get(~p"/impressum")
      |> html_response(200)
      |> footer_html()

    assert footer =~ ~s(href="#{BuildInfo.commit_url()}")
    assert footer =~ ">#{BuildInfo.commit_sha()}<"
    assert footer =~ "Stand: #{BuildInfo.berlin_date()}, #{BuildInfo.berlin_time()} Uhr"
    assert footer =~ "Letzter Commit (Berliner Zeit)"
  end

  test "and in English", %{conn: conn} do
    footer = conn |> get(~p"/impressum") |> html_response(200) |> footer_html()

    assert footer =~ "Last change: #{BuildInfo.berlin_date()} at #{BuildInfo.berlin_time()}"
    assert footer =~ "Last commit (Berlin time)"
  end

  defp footer_html(body) do
    [footer] = Regex.run(~r{<footer.*?</footer>}s, body)
    footer
  end
end

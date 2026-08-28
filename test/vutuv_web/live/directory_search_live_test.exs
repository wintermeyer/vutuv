defmodule VutuvWeb.DirectorySearchLiveTest do
  @moduledoc """
  The member directory's search box (`VutuvWeb.DirectorySearchLive`), embedded
  into `/system/members` by the controller, so it is mounted here with
  `live_isolated/3` the way the other `live_render` children are.

  Three things it has to get right, each of which has a way of failing
  silently. The field checkboxes narrow the search and at least one always
  stays ticked (an unticked box sends nothing, so "all three off" and "no
  preference" arrive identically and only one of them may mean "find
  nobody"). A large result set is revealed in bites and stops at a ceiling
  rather than rendering the whole membership. And the box works with no
  socket at all: `?q=` renders its results server-side and the "show more"
  control is a real link until the socket arrives to carry a `phx-click`.
  """

  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Directory

  setup do
    meier = insert_activated_user(first_name: "Anna", last_name: "Meier")
    mayer = insert_activated_user(first_name: "Bruno", last_name: "Mayer")

    quenstedt =
      insert_activated_user(
        first_name: "Clara",
        last_name: "Quenstedt",
        username: "quenstedtsearch"
      )

    opted_out =
      insert_activated_user(first_name: "Otto", last_name: "Meierhoff", noindex?: true)

    %{meier: meier, mayer: mayer, quenstedt: quenstedt, opted_out: opted_out}
  end

  defp mount_box(conn, session \\ %{}) do
    live_isolated(conn, VutuvWeb.DirectorySearchLive, session: session)
  end

  defp search(view, params) do
    render_change(view, "search", params)
  end

  describe "searching" do
    test "finds a member by last name as you type", %{conn: conn} do
      {:ok, view, _html} = mount_box(conn)

      html = search(view, %{"q" => "meier", "fields" => ~w(first_name last_name username)})

      assert html =~ "Meier, Anna"
      # A substring, not a prefix: "meier" inside "Meierhoff" is a hit.
      assert html =~ "Meierhoff, Otto"
      refute html =~ "Mayer, Bruno"
    end

    test "finds a member by first name and by username", %{conn: conn} do
      {:ok, view, _html} = mount_box(conn)

      assert search(view, %{"q" => "clara", "fields" => ~w(first_name last_name username)}) =~
               "Quenstedt, Clara"

      assert search(view, %{"q" => "quenstedtsea", "fields" => ~w(first_name last_name username)}) =~
               "Quenstedt, Clara"
    end

    test "says nothing found rather than showing an empty list", %{conn: conn} do
      {:ok, view, _html} = mount_box(conn)

      search(view, %{"q" => "nobodyhere", "fields" => ~w(first_name last_name username)})

      assert has_element?(view, "#directory-search-empty")
      refute has_element?(view, "#directory-search-count")
    end

    test "asks for more letters below the minimum instead of answering", %{conn: conn} do
      {:ok, view, _html} = mount_box(conn)

      search(view, %{"q" => "m", "fields" => ~w(first_name last_name username)})

      assert has_element?(view, "#directory-search-hint")
      refute has_element?(view, "#directory-search-results")
    end
  end

  describe "the field checkboxes" do
    test "all three start ticked", %{conn: conn} do
      {:ok, view, _html} = mount_box(conn)

      for field <- Directory.search_fields() do
        assert has_element?(view, ~s([data-search-field="#{field}"][checked]))
      end
    end

    test "unticking a field narrows what is searched", %{conn: conn} do
      {:ok, view, _html} = mount_box(conn)

      # "Otto" is a first name here and nobody's surname, so a last-name-only
      # search must come up empty where the full search finds him.
      assert search(view, %{"q" => "otto", "fields" => ~w(first_name last_name username)}) =~
               "Meierhoff, Otto"

      refute search(view, %{"q" => "otto", "fields" => ~w(last_name)}) =~ "Meierhoff, Otto"
    end

    test "unticking the last field ticks all three again", %{conn: conn} do
      {:ok, view, _html} = mount_box(conn)

      # Down to one field, then off: the form sends no `fields` key at all,
      # which is the same thing a no-preference request sends, and both mean
      # "look everywhere" rather than "look nowhere".
      #
      # Keeping the previous selection instead is the version that cannot be
      # rendered: `@fields` would not change, so the diff would carry nothing
      # for that checkbox and it would stay visibly unticked while the server
      # searched as though it were on. Found in a browser, not by a test —
      # which is why this one asserts the boxes and not only the results.
      search(view, %{"q" => "otto", "fields" => ~w(first_name)})
      refute has_element?(view, ~s([data-search-field="last_name"][checked]))

      html = search(view, %{"q" => "otto"})

      assert html =~ "Meierhoff, Otto"

      for field <- Directory.search_fields() do
        assert has_element?(view, ~s([data-search-field="#{field}"][checked]))
      end
    end
  end

  # One more than a bite, so the first press of "show more" is also the last and
  # both sides of the control are exercised. Zero-padded surnames keep the
  # filing order deterministic, so "the 26th" names one particular row.
  defp insert_a_bite_and_one do
    for i <- 1..(Directory.results_step() + 1) do
      n = String.pad_leading(Integer.to_string(i), 2, "0")
      insert_activated_user(first_name: "Rita", last_name: "Rasmussen#{n}")
    end

    Directory.results_step()
  end

  describe "a large result set" do
    setup do
      %{step: insert_a_bite_and_one()}
    end

    test "shows one bite with the full count, then reveals the next", %{conn: conn, step: step} do
      {:ok, view, _html} = mount_box(conn)

      html = search(view, %{"q" => "rasmussen", "fields" => ~w(last_name)})

      assert html =~ "Showing #{step} of #{step + 1} members."
      assert html =~ "Rasmussen01"
      refute html =~ "Rasmussen26"
      assert has_element?(view, "#directory-search-more")

      more = render_click(view, "show-more")

      assert more =~ "Rasmussen26"
      assert more =~ "#{step + 1} members found."
      refute has_element?(view, "#directory-search-more")
    end
  end

  describe "the row ceiling" do
    # Asserted on `results_limit/1` rather than on a result set, because the
    # only honest way to see the clamp through `search/3` is to insert more
    # members than the ceiling. A `length(users) <= ceiling` assertion over a
    # handful of fixtures passes with the clamp removed, which is no test at
    # all.
    test "a crafted ?show= cannot ask for more than the ceiling" do
      assert Directory.results_limit("100000") == Directory.results_ceiling()
      assert Directory.results_limit(100_000) == Directory.results_ceiling()
    end

    test "an honest request under the ceiling is passed through" do
      assert Directory.results_limit(Directory.results_step() * 2) ==
               Directory.results_step() * 2
    end

    test "anything that is not a positive number falls back to one bite" do
      for value <- [nil, "", "0", "-5", -5, 0, "abc", %{}] do
        assert Directory.results_limit(value) == Directory.results_step()
      end
    end
  end

  describe "without a socket" do
    test "a ?q= URL renders its results server-side", %{conn: conn} do
      html = conn |> get(~p"/system/members?q=meier") |> html_response(200)

      assert html =~ "Meier, Anna"
      assert html =~ "Meierhoff, Otto"
      refute html =~ "Mayer, Bruno"
    end

    test "the ?fields= param narrows the same way the checkboxes do", %{conn: conn} do
      html =
        conn
        |> get(~p"/system/members?#{[q: "otto", fields: ["last_name"]]}")
        |> html_response(200)

      refute html =~ "Meierhoff, Otto"
      assert html =~ "directory-search-empty"
    end

    test "show more is a real link, not a button that does nothing", %{conn: conn} do
      insert_a_bite_and_one()

      html = conn |> get(~p"/system/members?q=rasmussen") |> html_response(200)

      refute html =~ "directory-search-more\""
      assert html =~ "directory-search-more-link"
      assert html =~ "show=#{2 * Directory.results_step()}"
    end

    test "an opted-out member is listed, with rel=nofollow on the row", %{
      conn: conn,
      opted_out: opted_out,
      meier: meier
    } do
      html = conn |> get(~p"/system/members?q=meier") |> html_response(200)

      assert [_avatar, _name] = nofollow_links(html, opted_out.username)
      assert nofollow_links(html, meier.username) == []
    end
  end

  describe "the German render" do
    # vutuv is a German site, and `gettext.extract --merge` fuzzy-filled every
    # one of these msgids from an unrelated string — two of them with a
    # `%{query}` placeholder rewritten to `%{id}`, which renders as literal
    # text. So each new sentence is asserted by name rather than trusted.
    defp in_german(conn, path) do
      conn
      |> put_req_header("accept-language", "de-DE,de;q=0.9")
      |> get(path)
      |> html_response(200)
    end

    test "labels the box, its checkboxes and the result count", %{conn: conn} do
      html = in_german(conn, ~p"/system/members?q=meier")

      assert html =~ "Mitglied finden"
      assert html =~ "Mitglieder nach Namen suchen"
      assert html =~ "Vorname"
      assert html =~ "Nachname"
      assert html =~ "Benutzername"
      assert html =~ "2 Mitglieder gefunden."
    end

    test "names the query it found nothing for, and the letters it still wants", %{conn: conn} do
      assert in_german(conn, ~p"/system/members?q=nobodyhere") =~
               "Kein Mitglied für „nobodyhere“ gefunden."

      # The minimum is interpolated, not written into the translation: the
      # merge filled this one in with a hard-coded "drei".
      assert in_german(conn, ~p"/system/members?q=m") =~
               "mindestens #{Directory.min_query_chars()} Buchstaben"
    end
  end

  describe "indexability" do
    test "the bare directory stays indexable but a search result does not", %{conn: conn} do
      assert get_resp_header(get(conn, ~p"/system/members"), "x-robots-tag") == []

      assert get_resp_header(get(build_conn(), ~p"/system/members?q=meier"), "x-robots-tag") ==
               ["noindex"]
    end
  end
end

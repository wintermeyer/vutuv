defmodule VutuvWeb.ImportConnectionsLiveTest do
  @moduledoc """
  The LinkedIn contact finder (/settings/import/linkedin/connections, issue
  #1476): upload an export, see the contacts who are already members, narrow the
  list, and follow them — one pill at a time or a selection at once.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Social

  @headers "First Name,Last Name,URL,Email Address,Company,Position,Connected On"

  defp archive(rows) do
    csv = @headers <> "\n" <> Enum.join(rows, "\n") <> "\n"

    {:ok, {_name, binary}} =
      :zip.create(~c"export.zip", [{~c"Connections.csv", csv}], [:memory])

    binary
  end

  defp row(email, opts \\ []) do
    url = Keyword.get(opts, :url, "")
    "A,Contact,#{url},#{email},Acme,CEO,01 Jan 2020"
  end

  # Drives the page's own upload, exactly the way a member does.
  defp analyze(live, binary) do
    live
    |> file_input("#linkedin-connections-form", :archive, [
      %{
        name: "export.zip",
        content: binary,
        type: "application/zip",
        size: byte_size(binary)
      }
    ])
    |> render_upload("export.zip")

    live |> element("#linkedin-connections-form") |> render_submit()
  end

  defp member_with_public_email(value, attrs \\ []) do
    user = insert_activated_user(attrs)

    insert(:email,
      user: user,
      value: value,
      public?: true,
      md5sum: :crypto.hash(:md5, value) |> Base.encode16(case: :lower)
    )

    user
  end

  test "an anonymous visitor is sent away", %{conn: conn} do
    conn = get(conn, ~p"/settings/import/linkedin/connections")
    assert redirected_to(conn) == ~p"/"
  end

  test "it says what it does and does not do before anything is uploaded", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    {:ok, live, html} = live(conn, ~p"/settings/import/linkedin/connections")

    assert html =~ "Nobody is invited"
    assert html =~ "Nothing is stored"
    assert has_element?(live, "#linkedin-connections-form")
    refute has_element?(live, "#contact-matches")
  end

  # vutuv is a German site, and the whole page is new copy — including the
  # one-word labels gettext's fuzzy merge is most likely to have filled with
  # something plausible and wrong. So the German render is asserted by name.
  test "the German render says what the page is, in German", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, _user} = Vutuv.Accounts.update_user(user, %{"locale" => "de"})
    member_with_public_email("bekannt@example.com", first_name: "Bekannte", last_name: "Person")

    {:ok, live, html} = live(conn, ~p"/settings/import/linkedin/connections")

    assert html =~ "Wer aus Ihren LinkedIn-Kontakten ist schon hier?"
    assert html =~ "Niemand wird eingeladen"

    html = analyze(live, archive([row("bekannt@example.com")]))

    assert html =~ "Ihre Kontakte auf vutuv"
    assert html =~ "Gleiche E-Mail-Adresse wie Ihr Kontakt"
    assert html =~ "Folge ich noch nicht"
    assert html =~ "Alle 1 auswählen"

    html = live |> element("button", "Alle 1 auswählen") |> render_click()
    assert html =~ "Ausgewählten folgen"
  end

  describe "after an upload" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, conn: conn, user: user}
    end

    test "the contacts who are members are listed with the reason", %{conn: conn} do
      known = member_with_public_email("known@example.com", first_name: "Known", last_name: "One")

      {:ok, live, _html} = live(conn, ~p"/settings/import/linkedin/connections")

      html = analyze(live, archive([row("known@example.com"), row("stranger@example.com")]))

      assert html =~ "Known One"
      assert html =~ "Same email address"
      refute html =~ "stranger@example.com"
      assert has_element?(live, "#select-#{known.id}")
    end

    test "a contact who is not a member is not named anywhere", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/settings/import/linkedin/connections")

      html = analyze(live, archive([row("nobody@example.com")]))

      assert html =~ "None of your contacts is here yet"
    end

    test "a file that is not a LinkedIn archive is refused, not crashed on", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/settings/import/linkedin/connections")

      html = analyze(live, "this is not a zip file")

      assert html =~ "does not look like a LinkedIn data export"
    end

    test "select all then follow selected really follows them", %{conn: conn, user: user} do
      a = member_with_public_email("a@example.com")
      b = member_with_public_email("b@example.com")

      {:ok, live, _html} = live(conn, ~p"/settings/import/linkedin/connections")
      analyze(live, archive([row("a@example.com"), row("b@example.com")]))

      live |> element("button", "Select all") |> render_click()
      html = live |> element("button", "Follow selected") |> render_click()

      assert Social.user_follows_user?(user.id, a.id)
      assert Social.user_follows_user?(user.id, b.id)
      # The rows stay, now showing the new state rather than offering it again.
      assert html =~ "Following"
    end

    test "nothing is preselected, so the follow button is not even offered", %{conn: conn} do
      member_with_public_email("a@example.com")

      {:ok, live, _html} = live(conn, ~p"/settings/import/linkedin/connections")
      analyze(live, archive([row("a@example.com")]))

      refute has_element?(live, "button", "Follow selected")
    end

    test "one row's follow pill follows just that member", %{conn: conn, user: user} do
      target = member_with_public_email("a@example.com")

      {:ok, live, _html} = live(conn, ~p"/settings/import/linkedin/connections")
      analyze(live, archive([row("a@example.com")]))

      live
      |> element("button[phx-value-followee='#{target.id}']")
      |> render_click()

      assert Social.user_follows_user?(user.id, target.id)
    end

    test "the default view hides members you already follow, the filter brings them back",
         %{conn: conn, user: user} do
      followed =
        member_with_public_email("followed@example.com",
          first_name: "Already",
          last_name: "Followed"
        )

      follow!(user, followed)

      {:ok, live, _html} = live(conn, ~p"/settings/import/linkedin/connections")
      html = analyze(live, archive([row("followed@example.com")]))

      # Found and counted, but not in the "not following yet" view — and the
      # empty list says why, instead of reading as a failed search.
      assert html =~ "of your LinkedIn contacts"
      refute html =~ "Already Followed"
      assert html =~ "You already follow every contact we found."

      html = live |> element("button[phx-value-filter='all']") |> render_click()
      assert html =~ "Already Followed"
    end

    test "the search box narrows the list by name", %{conn: conn} do
      member_with_public_email("a@example.com", first_name: "Anna", last_name: "Alpha")
      member_with_public_email("b@example.com", first_name: "Bert", last_name: "Beta")

      {:ok, live, _html} = live(conn, ~p"/settings/import/linkedin/connections")
      analyze(live, archive([row("a@example.com"), row("b@example.com")]))

      html = live |> form("form[phx-change='search']", %{"q" => "anna"}) |> render_change()

      assert html =~ "Anna Alpha"
      refute html =~ "Bert Beta"
    end

    test "a long list is paged, and page two holds the rest", %{conn: conn} do
      for index <- 1..55 do
        member_with_public_email("member#{index}@example.com",
          first_name: "Member",
          last_name: String.pad_leading("#{index}", 3, "0")
        )
      end

      {:ok, live, _html} = live(conn, ~p"/settings/import/linkedin/connections")
      html = analyze(live, archive(for index <- 1..55, do: row("member#{index}@example.com")))

      assert html =~ "Showing 1-50 of 55."
      assert has_element?(live, "button[phx-value-page='2']")

      html = live |> element("button[phx-value-page='2']") |> render_click()
      assert html =~ "Showing 51-55 of 55."
    end

    test "a LinkedIn profile link matches too, and says so", %{conn: conn} do
      target = insert_activated_user(first_name: "Linked", last_name: "In")
      insert(:social_media_account, user: target, provider: "LinkedIn", value: "linked-in")

      {:ok, live, _html} = live(conn, ~p"/settings/import/linkedin/connections")

      html =
        analyze(live, archive([row("", url: "https://www.linkedin.com/in/Linked-In/")]))

      assert html =~ "Linked In"
      assert html =~ "Links the same LinkedIn profile"
    end
  end
end

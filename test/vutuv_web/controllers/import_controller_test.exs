defmodule VutuvWeb.ImportControllerTest do
  use VutuvWeb.ConnCase, async: true

  import Ecto.Query

  alias Vutuv.Imports.LinkedIn
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Tags.UserTag

  @sample_files [
    {"Positions.csv",
     "Company Name,Title,Description,Location,Started On,Finished On\nAcme,Engineer,,Berlin,2020,\n"},
    {"Skills.csv", "Name\nElixir\n"}
  ]

  defp zip_binary(files) do
    entries = Enum.map(files, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, {_name, binary}} = :zip.create(~c"export.zip", entries, [:memory])
    binary
  end

  defp upload_zip(files) do
    path = Path.join(System.tmp_dir!(), "linkedin_#{System.unique_integer([:positive])}.zip")
    File.write!(path, zip_binary(files))
    %Plug.Upload{path: path, filename: "export.zip", content_type: "application/zip"}
  end

  test "the upload form renders for the owner", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    html = conn |> get(~p"/settings/import/linkedin") |> html_response(200)
    assert html =~ "linkedin-import-form"
    # The drag-and-drop enhancement wraps the file input in a dropzone, but the
    # input must keep its name so the plain multipart POST still works with JS off.
    assert html =~ "data-dropzone"
    assert html =~ ~s(name="import[archive]")
  end

  test "the page links to LinkedIn's data export page and shows the screenshot", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    html = conn |> get(~p"/settings/import/linkedin") |> html_response(200)
    assert html =~ "https://www.linkedin.com/mypreferences/d/download-my-data"
    assert html =~ "/images/linkedin-download-my-data.webp"
  end

  test "a guest cannot open the import page", %{conn: conn} do
    # /settings is user-agnostic and login-required: the import page always
    # belongs to whoever is signed in, and a guest is turned away.
    conn = get(conn, ~p"/settings/import/linkedin")
    assert redirected_to(conn) == "/"
  end

  test "uploading an archive shows a preview of the candidates", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    conn =
      post(conn, ~p"/settings/import/linkedin", %{
        "import" => %{"archive" => upload_zip(@sample_files)}
      })

    body = html_response(conn, 200)
    assert body =~ "linkedin-import-preview"
    assert body =~ "Acme"
    assert body =~ "Elixir"
    # Each candidate group carries a select-all/deselect-all toggle (JS reveals
    # the button; it starts hidden and the checkboxes work without it).
    assert body =~ "data-select-group"
    assert body =~ "data-select-all"
  end

  # Issue #1477: a member who comes back to the importer could not tell whether
  # the last upload had already changed their profile. The preview now says so
  # before anything else, and tallies what the archive held per section.
  test "the preview says nothing was imported and tallies each section", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    insert(:work_experience, user: user, organization: "Acme", title: "Engineer")

    conn =
      post(conn, ~p"/settings/import/linkedin", %{
        "import" => %{"archive" => upload_zip(@sample_files)}
      })

    body = html_response(conn, 200)
    assert body =~ "data-import-analysis"
    assert body =~ "Nothing has been imported yet"
    # The additive behaviour is stated on the page, because an entry the member
    # edited on LinkedIn is NOT updated here and the unchecked row does not say so.
    assert body =~ "not updated either"

    # One position, already on the profile: found 1, present 1, nothing left.
    assert [_, found, present, available] =
             Regex.run(
               ~r/data-import-summary-row="positions".*?>(\d+)<.*?>(\d+)<.*?>(\d+)</s,
               body
             )

    assert {found, present, available} == {"1", "1", "0"}

    # A section this archive said nothing about is a row of zeros, not a claim
    # that a file is missing.
    assert body =~ ~s(data-import-summary-row="certifications")
  end

  test "the preview renders in German", %{conn: conn} do
    # vutuv is a German site; an English-only check would miss a missing or
    # fuzzy-filled translation on the whole panel.
    {conn, _user} = create_and_login_user(conn)

    conn =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de")
      |> post(~p"/settings/import/linkedin", %{
        "import" => %{"archive" => upload_zip(@sample_files)}
      })

    body = html_response(conn, 200)
    assert body =~ "Analyse abgeschlossen"
    assert body =~ "Es wurde noch nichts importiert"
    assert body =~ "Schon im Profil"
    assert body =~ "Zum Import bereit"
  end

  test "the uploaded temp file is deleted after parsing", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    upload = upload_zip(@sample_files)

    post(conn, ~p"/settings/import/linkedin", %{"import" => %{"archive" => upload}})

    refute File.exists?(upload.path)
  end

  # The regression behind the "500 on upload" bug report: a CSV re-saved in
  # Excel (Windows-1252/Latin-1) before re-zipping used to crash the preview's
  # Jason.encode! and render the 500 page instead of anything helpful.
  test "an archive with a Latin-1 encoded CSV still previews", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    latin1_csv =
      :unicode.characters_to_binary(
        "Company Name,Title,Description,Location,Started On,Finished On\n" <>
          "Müller GmbH,Geschäftsführer,,Berlin,2020,\n",
        :utf8,
        :latin1
      )

    conn =
      post(conn, ~p"/settings/import/linkedin", %{
        "import" => %{"archive" => upload_zip([{"Positions.csv", latin1_csv}])}
      })

    body = html_response(conn, 200)
    assert body =~ "linkedin-import-preview"
    assert body =~ "Müller GmbH"
  end

  test "an oversized upload is rejected with the friendly flash", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    path = Path.join(System.tmp_dir!(), "big_#{System.unique_integer([:positive])}.zip")
    File.write!(path, :binary.copy(<<0>>, 50_000_001))
    on_exit(fn -> File.rm(path) end)
    upload = %Plug.Upload{path: path, filename: "big.zip", content_type: "application/zip"}

    conn =
      post(conn, ~p"/settings/import/linkedin", %{"import" => %{"archive" => upload}})

    assert redirected_to(conn) == ~p"/settings/import/linkedin"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "50 MB"
  end

  test "a non-zip upload is rejected with a flash", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    path = Path.join(System.tmp_dir!(), "notzip_#{System.unique_integer([:positive])}.zip")
    File.write!(path, "this is not a zip")
    upload = %Plug.Upload{path: path, filename: "x.zip", content_type: "application/zip"}

    conn =
      post(conn, ~p"/settings/import/linkedin", %{"import" => %{"archive" => upload}})

    assert redirected_to(conn) == ~p"/settings/import/linkedin"
  end

  test "confirm imports only the checked candidates", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, parsed} = LinkedIn.parse(zip_binary(@sample_files))
    payload = Jason.encode!(LinkedIn.payload_map(parsed))
    position_id = hd(parsed.positions).id

    # Select the position, leave the Elixir skill unchecked.
    conn =
      post(conn, ~p"/settings/import/linkedin/apply", %{
        "payload" => payload,
        "selected" => [position_id]
      })

    assert redirected_to(conn) == ~p"/#{user}"
    assert Repo.get_by(WorkExperience, user_id: user.id, organization: "Acme")

    # The unchecked Elixir skill was not imported; only the three registration
    # tags the account signed up with exist.
    refute Repo.exists?(
             from(ut in UserTag,
               join: t in assoc(ut, :tag),
               where: ut.user_id == ^user.id and t.name == "Elixir"
             )
           )
  end

  # Issue #1477: "already on your profile" and "another member has claimed it"
  # used to share one sentence, so an entry that never landed was reported as
  # one the member already had.
  test "the confirmation flash tells a duplicate apart from a blocked entry", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    {:ok, parsed} = LinkedIn.parse(zip_binary(@sample_files))
    payload = Jason.encode!(LinkedIn.payload_map(parsed))
    selected = [hd(parsed.positions).id]

    apply_import = fn conn ->
      post(conn, ~p"/settings/import/linkedin/apply", %{
        "payload" => payload,
        "selected" => selected
      })
    end

    first = apply_import.(conn)
    assert Phoenix.Flash.get(first.assigns.flash, :info) =~ "Imported 1 work experience."

    second = apply_import.(conn)
    flash = Phoenix.Flash.get(second.assigns.flash, :info)
    assert flash =~ "Nothing new to import."
    assert flash =~ "already on your profile"
    refute flash =~ "could not be added"
  end

  test "a social account another member holds is named as such in the flash", %{conn: conn} do
    # A literal of this file's own: (provider, value) is globally unique, and
    # two async files inserting the same handle convoy on that index.
    handle = "importclaimflash"
    other = insert(:user)
    insert(:social_media_account, user: other, provider: "Twitter", value: handle)

    {conn, _user} = create_and_login_user(conn)

    profile_csv =
      "First Name,Last Name,Maiden Name,Address,Birth Date,Headline,Summary,Industry," <>
        "Zip Code,Geo Location,Twitter Handles,Websites,Instant Messengers\n" <>
        "Stefan,Wintermeyer,,,,,,,,,[#{handle}],,\n"

    {:ok, parsed} = LinkedIn.parse(zip_binary([{"Profile.csv", profile_csv}]))

    conn =
      post(conn, ~p"/settings/import/linkedin/apply", %{
        "payload" => Jason.encode!(LinkedIn.payload_map(parsed)),
        "selected" => Enum.map(parsed.social, & &1.id)
      })

    flash = Phoenix.Flash.get(conn.assigns.flash, :info)
    assert flash =~ "already claimed it"
    refute flash =~ "already on your profile"
  end

  # A profile carries at most Vutuv.Tags.max_user_tags/0 tags, and an archive
  # cheerfully offers fifty skills. The preview used to tick every one of them
  # and the confirm step then dropped the overflow with a message blaming
  # duplicates (issue #1478).
  describe "the tag section's ceiling (issue #1478)" do
    defp skill_files(names), do: [{"Skills.csv", "Name\n" <> Enum.join(names, "\n") <> "\n"}]

    defp fill_tags(user, count) do
      for _ <- 1..count, do: insert(:user_tag, user: user, tag: build(:tag))
      user
    end

    defp preview(conn, files) do
      conn
      |> post(~p"/settings/import/linkedin", %{"import" => %{"archive" => upload_zip(files)}})
      |> html_response(200)
    end

    defp checked_skill_boxes(body) do
      body
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s([data-select-limit] input[type="checkbox"][checked]))
      |> Enum.count()
    end

    test "the preview ticks no more skills than the profile has room for", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # The account signs up with three tags, so eleven of the fifteen are left
      # once one more is attached.
      fill_tags(user, 1)
      names = for i <- 1..30, do: "Ceiling Skill #{i}"

      body = preview(conn, skill_files(names))

      assert body =~ ~s(data-select-limit="11")
      assert checked_skill_boxes(body) == 11
      assert body =~ "You have 4 of 15 tags."
      # The live half counts what is selected, so the sentence is true on
      # arrival — with the free slots already ticked, "11 more can be picked"
      # would read as a zero.
      assert body =~ "11 of 11 free slots selected."
    end

    test "a full profile ticks nothing and points at the tags editor", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_tags(user, Vutuv.Tags.max_user_tags() - 3)

      body = preview(conn, skill_files(["Ceiling Skill A", "Ceiling Skill B"]))

      assert body =~ ~s(data-select-limit="0")
      assert checked_skill_boxes(body) == 0
      assert body =~ "There is no room for more."
      assert body =~ ~s(href="/settings/tags")
    end

    test "the German preview names the ceiling in German", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_tags(user, 1)

      body =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> preview(skill_files(["Ceiling Skill C"]))

      assert body =~ "Sie haben 4 von 15 Tags."
      assert body =~ "1 von 11 freien Plätzen ausgewählt."
      # The msgid this one is closest to is "Remove date of birth", which is
      # what --merge fuzzy-filled it with (the .po trap in CLAUDE.md).
      refute body =~ "Geburtsdatum entfernen"
    end

    test "confirm reports the tags that did not fit as such", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_tags(user, Vutuv.Tags.max_user_tags() - 3 - 1)
      names = for i <- 1..5, do: "Ceiling Skill F#{i}"
      {:ok, parsed} = LinkedIn.parse(zip_binary(skill_files(names)))

      conn =
        post(conn, ~p"/settings/import/linkedin/apply", %{
          "payload" => Jason.encode!(LinkedIn.payload_map(parsed)),
          "selected" => Enum.map(parsed.skills, & &1.id)
        })

      assert redirected_to(conn) == ~p"/#{user}"
      flash = Phoenix.Flash.get(conn.assigns.flash, :info)
      assert flash =~ "Imported 1 tag."
      assert flash =~ "4 tags did not fit: your profile holds at most 15."
      # The old sentence claimed those four were already on the profile.
      refute flash =~ "already on your profile"
      refute flash =~ "could not be added"
    end
  end
end

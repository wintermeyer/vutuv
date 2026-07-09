defmodule VutuvWeb.CVControllerTest do
  @moduledoc """
  The formatted CV at /:slug/cv (issue #841): the print-ready view and the
  file downloads (HTML / LaTeX / Word / OpenDocument / JSON Resume). Public
  like the profile — every viewer gets the CV built from the data they may
  see (private emails stay owner-only) — and every part is excludable via
  the `?hide=` selection so a recruiter can tailor or anonymize it.
  """
  use VutuvWeb.ConnCase

  alias Ecto.Changeset
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo

  @login %{
    "emails" => %{"0" => %{"value" => "cv-owner@example.com"}},
    "first_name" => "Erika",
    "last_name" => "Beispiel",
    "gender" => "female",
    "tag_list" => @registration_tags
  }

  # A profile with every CV section filled: the three work-experience
  # categories from issue #840, two education categories (#849), a link, a
  # spoken language (#865), a certificate (#859), a social media account and
  # personal details. The employment description carries the characters each
  # format must escape plus Markdown (issue #905) each format must render
  # per its own vocabulary (issue #920).
  defp seed_profile(user) do
    insert(:work_experience,
      user: user,
      title: "Senior Developer",
      organization: "ACME GmbH",
      kind: "employment",
      description:
        "Shipping <fast> & 100% maintainable code_bases\n\n" <>
          "- **Led** the [platform](https://acme.example/docs) team\n- Cut deploy times",
      start_month: 3,
      start_year: 2020,
      end_month: nil,
      end_year: nil
    )

    insert(:work_experience,
      user: user,
      title: "Werkstudent",
      organization: "Beispiel AG",
      kind: "internship",
      start_year: 2018,
      end_year: 2019
    )

    insert(:work_experience,
      user: user,
      title: "Jugendtrainer",
      organization: "SV Musterstadt",
      kind: "volunteer",
      start_year: 2015,
      end_year: 2017
    )

    insert(:education,
      user: user,
      school: "Universität Bremen",
      degree: "BSc",
      field_of_study: "Informatik",
      kind: "university",
      start_year: 2014,
      end_year: 2018
    )

    insert(:url, user: user, value: "https://blog.example.org/", description: "Blog")

    insert(:address,
      user: user,
      line_1: "Musterstraße 1",
      zip_code: "12345",
      city: "Musterstadt",
      country: "Deutschland"
    )

    insert(:language, user: user, language_code: "en", proficiency: "c2")

    insert(:qualification,
      user: user,
      name: "AWS Certified Solutions Architect",
      issuer: "Amazon Web Services",
      awarded_year: 2023
    )

    insert(:social_media_account, user: user, provider: "GitHub", value: "octocat")

    user
    |> Changeset.change(%{birthdate: ~D[1990-05-15]})
    |> Repo.update!()
  end

  defp login_with_profile(conn) do
    {conn, user} = create_and_login_user(conn, @login)
    {conn, seed_profile(user)}
  end

  describe "OpenGraph" do
    test "names the member's CV in the title and description", %{conn: conn} do
      owner = seed_profile(insert(:activated_user, first_name: "Erika", last_name: "Beispiel"))

      body = conn |> get(~p"/#{owner}/cv") |> html_response(200)

      # The shared-link card reads as this person's CV, not the site pitch.
      assert body =~ ~s(<meta property="og:title" content="CV of Erika Beispiel">)
      assert body =~ ~s(property="og:description" content="The CV of Erika Beispiel on vutuv)
      refute body =~ "Your Fast and Free Career Network"
      # The avatar stays the OG image (og:type profile), so the card shows the face.
      assert body =~ ~s(<meta property="og:type" content="profile">)
    end
  end

  describe "the profile page" do
    test "links the CV builder for every visitor", %{conn: conn} do
      owner = seed_profile(insert(:activated_user))

      body = conn |> get(~p"/#{owner}") |> html_response(200)

      # The card offers only the "Open CV" button; the download formats live
      # in the builder, not on the profile.
      assert body =~ ~s(href="/#{owner.username}/cv")
      refute body =~ ~s(href="/#{owner.username}/cv/download/docx")
    end
  end

  describe "the print-ready view" do
    test "renders a standalone print document with every section", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      body = conn |> get(~p"/#{user}/cv/print") |> html_response(200)

      # A standalone document with its own print stylesheet — not an app page.
      assert body =~ "@media print"
      refute body =~ "app-shell-lv"

      assert body =~ "Erika Beispiel"
      assert body =~ "Senior Developer"
      assert body =~ "ACME GmbH"
      # The issue #840 + #849 categories become the CV sections.
      assert body =~ "Werkstudent"
      assert body =~ "Jugendtrainer"
      assert body =~ "Universität Bremen"
      assert body =~ "blog.example.org"
      assert body =~ "cv-owner@example.com"
      assert body =~ "alpha-tag"

      # The vutuv profile link is a real clickable link, not plain text.
      profile_url = "#{VutuvWeb.Endpoint.url()}/#{user.username}"
      assert body =~ ~s(<a href="#{profile_url}">#{profile_url}</a>)

      # The user-written description is escaped, never raw HTML.
      assert body =~ "Shipping &lt;fast&gt; &amp; 100% maintainable code_bases"
      refute body =~ "<fast>"

      # Its Markdown renders like on the profile (issue #920): bold, a real
      # bullet list, a clickable link — no literal markers.
      assert body =~ "<strong>Led</strong>"
      assert body =~ ~r{<li>.*platform.*</li>}s
      assert body =~ ~s(href="https://acme.example/docs")
      refute body =~ "**Led**"
    end

    test "carries the newer sections and honors hiding them", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      body = conn |> get(~p"/#{user}/cv/print") |> html_response(200)

      # Sections added after the CV shipped are all present: spoken languages
      # (#865), certificates (#859), social media accounts and personal details.
      assert body =~ "English"
      assert body =~ "AWS Certified Solutions Architect"
      assert body =~ "GitHub"
      assert body =~ "octocat"
      # The date of birth (its year is unique — work years differ).
      assert body =~ "1990"

      # Each new part is excludable through ?hide, like every other.
      hidden =
        conn
        |> recycle()
        |> get(~p"/#{user}/cv/print?#{[hide: "social_media,languages,birthdate"]}")
        |> html_response(200)

      refute hidden =~ "octocat"
      refute hidden =~ "English"
      refute hidden =~ "1990"
      # An untouched new section stays.
      assert hidden =~ "AWS Certified Solutions Architect"
    end

    test "honors the ?hide selection: sections, entries and identity fields", %{conn: conn} do
      {conn, user} = login_with_profile(conn)
      internship = Repo.get_by(WorkExperience, title: "Werkstudent", user_id: user.id)

      # Hide a whole section (tags), a single entry (the internship) and the
      # name (anonymize).
      hide = "tags,name,#{internship.id}"
      body = conn |> get(~p"/#{user}/cv/print?#{[hide: hide]}") |> html_response(200)

      refute body =~ "alpha-tag"
      refute body =~ "Werkstudent"
      refute body =~ "Erika Beispiel"
      # The rest of the CV is still there.
      assert body =~ "Senior Developer"
      assert body =~ "Universität Bremen"
    end
  end

  describe "the downloads" do
    test "HTML is a document attachment", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      conn = get(conn, ~p"/#{user}/cv/download/html")

      assert response_content_type(conn, :html) =~ "text/html"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "cv-#{user.username}"
      assert conn.resp_body =~ "Erika Beispiel"
    end

    test "an anonymized download drops the username from the filename", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      conn = get(conn, ~p"/#{user}/cv/download/html?#{[hide: "name"]}")

      assert [disposition] = get_resp_header(conn, "content-disposition")
      refute disposition =~ user.username
      refute conn.resp_body =~ "Erika Beispiel"
    end

    test "LaTeX escapes the specials and carries every section", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      body = conn |> get(~p"/#{user}/cv/download/tex") |> response(200)

      assert body =~ "\\documentclass"
      assert body =~ "Erika Beispiel"
      assert body =~ "Universität Bremen"
      assert body =~ "\\& 100\\% maintainable code\\_bases"
      refute body =~ "& 100% maintainable"

      # The description's Markdown list becomes a real itemize; inline
      # markers are stripped, the link's URL survives as text (issue #920).
      assert body =~ "\\begin{itemize}"
      assert body =~ "\\item Led the platform (https://acme.example/docs) team"
      refute body =~ "**Led**"
    end

    test "the .docx is a valid OOXML package, honoring ?hide", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      conn = get(conn, ~p"/#{user}/cv/download/docx?#{[hide: "tags"]}")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "wordprocessingml.document"

      {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
      files = Map.new(files, fn {name, data} -> {List.to_string(name), data} end)

      assert Map.has_key?(files, "[Content_Types].xml")
      document = Map.fetch!(files, "word/document.xml")
      assert document =~ "Erika Beispiel"
      assert document =~ "Senior Developer"
      assert document =~ "Shipping &lt;fast&gt; &amp; 100% maintainable"
      refute document =~ "<fast>"
      # The description's Markdown list becomes bulleted paragraphs with the
      # markers stripped and the link URL kept (issue #920).
      assert document =~ "• Led the platform (https://acme.example/docs) team"
      assert document =~ "• Cut deploy times"
      refute document =~ "**Led**"
      # tags were hidden.
      refute document =~ "alpha-tag"
    end

    test "the .odt is a valid ODF package", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      conn = get(conn, ~p"/#{user}/cv/download/odt")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "opendocument.text"
      # The ODF magic: an uncompressed "mimetype" first in the archive.
      assert binary_part(conn.resp_body, 30, 8) == "mimetype"

      {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
      files = Map.new(files, fn {name, data} -> {List.to_string(name), data} end)
      assert files["mimetype"] == "application/vnd.oasis.opendocument.text"
      content = Map.fetch!(files, "content.xml")
      assert content =~ "SV Musterstadt"
      # The description's Markdown renders as stripped bulleted paragraphs
      # here too (issue #920).
      assert content =~ "• Cut deploy times"
      refute content =~ "**Led**"
    end

    test "the JSON Resume maps the categories onto the schema", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      resume = conn |> get(~p"/#{user}/cv/download/json") |> json_response(200)

      assert resume["basics"]["name"] == "Erika Beispiel"
      assert resume["basics"]["email"] == "cv-owner@example.com"

      positions = Enum.map(resume["work"], & &1["position"])
      assert "Senior Developer" in positions
      assert "Werkstudent" in positions

      assert [%{"organization" => "SV Musterstadt"}] = resume["volunteer"]
      assert [%{"institution" => "Universität Bremen"}] = resume["education"]
      assert Enum.any?(resume["skills"], &(&1["name"] == "alpha-tag"))

      # The address becomes basics.location, the links become basics.profiles.
      assert resume["basics"]["location"]["address"] =~ "Musterstadt"

      assert Enum.any?(
               resume["basics"]["profiles"],
               &(&1["network"] == "Blog" and &1["url"] == "https://blog.example.org/")
             )

      # Social media accounts join basics.profiles too, with the handle as the
      # username and the derived profile URL.
      assert Enum.any?(
               resume["basics"]["profiles"],
               &(&1["network"] == "GitHub" and &1["username"] == "octocat" and
                   &1["url"] =~ "github.com/octocat")
             )

      # Spoken languages and certificates map onto their own schema sections.
      assert Enum.any?(resume["languages"], &(&1["language"] == "English"))
      assert Enum.any?(resume["certificates"], &(&1["name"] =~ "AWS Certified"))

      # A JSON Resume summary is CommonMark by spec, so the raw Markdown
      # source rides along untouched (issue #920).
      senior = Enum.find(resume["work"], &(&1["position"] == "Senior Developer"))
      assert senior["summary"] =~ "- **Led** the [platform](https://acme.example/docs) team"
    end

    test "an unknown format is a 404", %{conn: conn} do
      {conn, user} = login_with_profile(conn)
      assert conn |> get(~p"/#{user}/cv/download/pdf") |> response(404)
    end
  end

  describe "access & privacy" do
    test "a guest downloads the CV, with public contact data only", %{conn: conn} do
      owner = seed_profile(insert(:activated_user))
      insert(:email, user: owner, value: "visible@example.com", public?: true)
      insert(:email, user: owner, value: "secret@example.com", public?: false)

      body = conn |> get(~p"/#{owner}/cv/print") |> html_response(200)
      assert body =~ "Senior Developer"
      assert body =~ "visible@example.com"
      refute body =~ "secret@example.com"

      docx = conn |> recycle() |> get(~p"/#{owner}/cv/download/docx")
      assert docx.status == 200
      refute docx.resp_body =~ "secret@example.com"
    end

    test "the owner's own CV carries their private email", %{conn: conn} do
      {conn, user} = login_with_profile(conn)
      refute Enum.any?(Repo.preload(user, :emails).emails, & &1.public?)

      body = conn |> get(~p"/#{user}/cv/print") |> html_response(200)
      assert body =~ "cv-owner@example.com"
    end

    test "a machine-opted-out member's JSON downloads for any viewer", %{conn: conn} do
      # The JSON Resume is a member-initiated export of the same public CV as
      # every other download format, so the agent-doc opt-out no longer gates
      # it: a guest gets the same 200 as the human-use formats.
      owner =
        :activated_user
        |> insert(noindex?: true, noai?: true)
        |> seed_profile()

      resume = conn |> get(~p"/#{owner}/cv/download/json") |> json_response(200)
      assert resume["basics"]["name"]

      assert conn |> recycle() |> get(~p"/#{owner}/cv/download/docx") |> response(200)
      assert conn |> recycle() |> get(~p"/#{owner}/cv/print") |> response(200)
    end
  end
end

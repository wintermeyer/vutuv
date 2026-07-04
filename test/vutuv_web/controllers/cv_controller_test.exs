defmodule VutuvWeb.CVControllerTest do
  @moduledoc """
  The formatted CV download (issue #841): the owner turns their profile into
  a print-ready Lebenslauf at /:slug/export/cv/*, offered as HTML / LaTeX /
  Word (.docx) / OpenDocument (.odt) / JSON Resume. Owner-only, like the
  GDPR export beside it — the CV bundles the member's contact details.
  """
  use VutuvWeb.ConnCase

  @login %{
    "emails" => %{"0" => %{"value" => "cv-owner@example.com"}},
    "first_name" => "Erika",
    "last_name" => "Beispiel",
    "gender" => "female",
    "tag_list" => @registration_tags
  }

  # A profile with every CV section filled: the three work-experience
  # categories from issue #840, an education, a link. The employment
  # description carries the characters each format must escape.
  defp seed_profile(user) do
    insert(:work_experience,
      user: user,
      title: "Senior Developer",
      organization: "ACME GmbH",
      kind: "employment",
      description: "Shipping <fast> & 100% maintainable code_bases",
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
      description: nil,
      start_month: nil,
      start_year: 2018,
      end_month: nil,
      end_year: 2019
    )

    insert(:work_experience,
      user: user,
      title: "Jugendtrainer",
      organization: "SV Musterstadt",
      kind: "volunteer",
      description: nil,
      start_month: nil,
      start_year: 2015,
      end_month: nil,
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

    # A second category (issue #849), so the CV splits education into its
    # kind sections instead of the single "Education" heading.
    insert(:education,
      user: user,
      school: "IHK Bremen",
      degree: "Fachinformatiker",
      field_of_study: nil,
      kind: "apprenticeship",
      start_year: 2011,
      end_year: 2014
    )

    insert(:url, user: user, value: "https://blog.example.org/", description: "Blog")
    user
  end

  defp login_with_profile(conn) do
    {conn, user} = create_and_login_user(conn, @login)
    {conn, seed_profile(user)}
  end

  describe "the export overview page" do
    test "offers the preview and every download format", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      conn = get(conn, ~p"/#{user}/export")
      body = html_response(conn, 200)

      # Assert the rendered hrefs, not just the routes we know exist.
      assert body =~ ~s(href="/#{user.username}/export/cv/preview")

      for format <- ~w(html tex docx odt json) do
        assert body =~ ~s(href="/#{user.username}/export/cv/#{format}")
      end
    end

    test "is linked from the settings hub", %{conn: conn} do
      {conn, user} = create_and_login_user(conn, @login)

      conn = get(conn, ~p"/settings")
      assert html_response(conn, 200) =~ ~s(href="/#{user.username}/export")
    end
  end

  describe "the print-ready preview" do
    test "renders a standalone print document with every section", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      conn = get(conn, ~p"/#{user}/export/cv/preview")
      body = html_response(conn, 200)

      # A standalone document with its own print stylesheet — not an app page.
      assert body =~ "@media print"
      refute body =~ "app-shell-lv"

      assert body =~ "Erika Beispiel"
      assert body =~ "Senior Developer"
      assert body =~ "ACME GmbH"
      # The issue #840 categories become the CV sections, in CV order.
      assert body =~ "Werkstudent"
      assert body =~ "Jugendtrainer"
      assert body =~ "Universität Bremen"
      # A mixed education list splits into its issue #849 categories.
      assert body =~ "Higher Education"
      assert body =~ "Vocational Training"
      assert body =~ "IHK Bremen"
      assert body =~ "blog.example.org"
      assert body =~ "cv-owner@example.com"
      assert body =~ "alpha-tag"
      assert body =~ user.username

      # The user-written description is escaped, never raw HTML.
      assert body =~ "Shipping &lt;fast&gt; &amp; 100% maintainable code_bases"
      refute body =~ "<fast>"
    end
  end

  describe "the downloads" do
    test "HTML is the same document as an attachment", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      conn = get(conn, ~p"/#{user}/export/cv/html")

      assert response_content_type(conn, :html) =~ "text/html"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "cv-#{user.username}"
      assert disposition =~ ".html"
      assert conn.resp_body =~ "Erika Beispiel"
    end

    test "LaTeX escapes the specials and carries every section", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      conn = get(conn, ~p"/#{user}/export/cv/tex")

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ".tex"

      body = conn.resp_body
      assert body =~ "\\documentclass"
      assert body =~ "Erika Beispiel"
      assert body =~ "ACME GmbH"
      assert body =~ "Universität Bremen"
      # <, &, %, _ from the description, LaTeX-escaped.
      assert body =~ "\\& 100\\% maintainable code\\_bases"
      refute body =~ "& 100% maintainable"
    end

    test "the .docx is a valid OOXML package with the CV text", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      conn = get(conn, ~p"/#{user}/export/cv/docx")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "wordprocessingml.document"

      {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
      files = Map.new(files, fn {name, data} -> {List.to_string(name), data} end)

      assert Map.has_key?(files, "[Content_Types].xml")
      document = Map.fetch!(files, "word/document.xml")
      assert document =~ "Erika Beispiel"
      assert document =~ "Senior Developer"
      assert document =~ "Universität Bremen"
      # XML-escaped user text: the raw <fast> must never appear.
      assert document =~ "Shipping &lt;fast&gt; &amp; 100% maintainable"
      refute document =~ "<fast>"
    end

    test "the .odt is a valid ODF package with the CV text", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      conn = get(conn, ~p"/#{user}/export/cv/odt")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "opendocument.text"

      # The ODF magic: an uncompressed "mimetype" as the archive's first
      # entry (its name sits at byte 30 of the first local file header).
      assert binary_part(conn.resp_body, 30, 8) == "mimetype"

      {:ok, files} = :zip.unzip(conn.resp_body, [:memory])
      files = Map.new(files, fn {name, data} -> {List.to_string(name), data} end)

      assert files["mimetype"] == "application/vnd.oasis.opendocument.text"
      content = Map.fetch!(files, "content.xml")
      assert content =~ "Erika Beispiel"
      assert content =~ "SV Musterstadt"
      assert content =~ "Shipping &lt;fast&gt; &amp; 100% maintainable"
    end

    test "the JSON Resume maps the categories onto the schema", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      conn = get(conn, ~p"/#{user}/export/cv/json")

      assert response_content_type(conn, :json) =~ "application/json"
      resume = Jason.decode!(conn.resp_body)

      assert resume["basics"]["name"] == "Erika Beispiel"
      assert resume["basics"]["email"] == "cv-owner@example.com"
      assert resume["basics"]["url"] =~ user.username

      # employment + internship land in "work", volunteer in "volunteer".
      positions = Enum.map(resume["work"], & &1["position"])
      assert "Senior Developer" in positions
      assert "Werkstudent" in positions

      acme = Enum.find(resume["work"], &(&1["name"] == "ACME GmbH"))
      assert acme["startDate"] == "2020-03"
      refute Map.has_key?(acme, "endDate")

      assert [%{"organization" => "SV Musterstadt", "position" => "Jugendtrainer"}] =
               resume["volunteer"]

      institutions = Enum.map(resume["education"], & &1["institution"])
      assert "Universität Bremen" in institutions
      assert "IHK Bremen" in institutions

      uni = Enum.find(resume["education"], &(&1["institution"] == "Universität Bremen"))
      assert uni["studyType"] == "BSc"
      assert uni["area"] == "Informatik"

      assert Enum.any?(resume["skills"], &(&1["name"] == "alpha-tag"))
    end

    test "an unknown format is a 404, not a crash", %{conn: conn} do
      {conn, user} = login_with_profile(conn)

      conn = get(conn, ~p"/#{user}/export/cv/pdf")
      assert conn.status == 404
    end
  end

  describe "access" do
    test "a guest is sent to the login flow", %{conn: conn} do
      owner = seed_profile(insert(:activated_user))

      for path <- [
            ~p"/#{owner}/export",
            ~p"/#{owner}/export/cv/preview",
            ~p"/#{owner}/export/cv/html"
          ] do
        assert conn |> recycle() |> get(path) |> redirected_to() == "/"
      end
    end

    test "another member gets the 403 page — a CV bundles contact details", %{conn: conn} do
      owner = seed_profile(insert(:activated_user))
      {conn, _visitor} = create_and_login_user(conn)

      for path <- [
            ~p"/#{owner}/export/cv/preview",
            ~p"/#{owner}/export/cv/docx"
          ] do
        assert conn |> recycle() |> get(path) |> html_response(403)
      end
    end
  end
end

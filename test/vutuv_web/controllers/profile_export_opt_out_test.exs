defmodule VutuvWeb.ProfileExportOptOutTest do
  @moduledoc """
  A member who opted out of BOTH search engines (`noindex?`) and AI agents
  (`noai?`) has said no to every machine use of their profile, so their
  profile namespace serves no agent documents at all: the
  `.md`/`.txt`/`.json`/`.xml` URLs (and their `Accept`-negotiated twins)
  answer 404 across the profile, its section pages and its people lists;
  the HTML page advertises no alternates and shows a short note where the
  "Other formats" card normally links them. One opt-out alone keeps the
  documents flowing, with the choice embedded in every format (headers,
  JSON/XML fields, Markdown frontmatter, text footer). The vCard stays
  either way: a contact-exchange format for humans, not agent food.
  """

  use VutuvWeb.ConnCase, async: true

  setup do
    blocked =
      insert_activated_user(
        first_name: "Bea",
        last_name: "Blocked",
        noindex?: true,
        noai?: true
      )

    insert(:work_experience, user: blocked, title: "Baker", organization: "Backstube")
    %{blocked: blocked}
  end

  test "a fully opted-out profile serves no agent documents", %{blocked: blocked} do
    for ext <- [".md", ".txt", ".json", ".xml"] do
      assert get(build_conn(), "/#{blocked.username}#{ext}").status == 404,
             "expected /#{blocked.username}#{ext} to 404"
    end
  end

  test "Accept negotiation is refused the same way", %{blocked: blocked} do
    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/#{blocked.username}")

    assert conn.status == 404
  end

  test "the section pages and people lists are covered too", %{blocked: blocked} do
    for path <- [
          "/#{blocked.username}/work_experiences.md",
          "/#{blocked.username}/emails.json",
          "/#{blocked.username}/followers.txt",
          "/#{blocked.username}/tags.xml"
        ] do
      assert get(build_conn(), path).status == 404, "expected #{path} to 404"
    end
  end

  test "the vCard keeps serving (a human contact-exchange format)", %{blocked: blocked} do
    conn = get(build_conn(), "/#{blocked.username}.vcf")

    assert conn.status == 200
    assert conn.resp_body =~ "FN:Bea Blocked"
  end

  test "the HTML profile shows a note instead of the format chips", %{blocked: blocked} do
    conn = get(build_conn(), "/#{blocked.username}")
    html = html_response(conn, 200)

    assert html =~ "not offered as"
    # No head alternates, no chip links to the dead extension URLs; the
    # vCard chip stays.
    refute html =~ "#{blocked.username}.md"
    refute html =~ "#{blocked.username}.json"
    assert html =~ "#{blocked.username}.vcf"
    # The Link header advertises no agent-format alternates either (the
    # posts RSS feed alternate deliberately stays — posts are out of scope).
    link_header = conn |> get_resp_header("link") |> Enum.join()
    refute link_header =~ "#{blocked.username}.md"
    refute link_header =~ "#{blocked.username}.json"
  end

  test "one opt-out alone keeps the docs and embeds the choice in the body" do
    noindex_only = insert_activated_user(noindex?: true, noai?: false)

    md = get(build_conn(), "/#{noindex_only.username}.md").resp_body
    assert md =~ "noindex: true"
    refute md =~ "noai: true"

    txt = get(build_conn(), "/#{noindex_only.username}.txt").resp_body
    assert txt =~ "noindex: true"

    noai_only = insert_activated_user(noindex?: false, noai?: true)

    md = get(build_conn(), "/#{noai_only.username}.md").resp_body
    assert md =~ "noai: true"
    refute md =~ "noindex: true"
  end

  test "an open member's docs carry no opt-out flags" do
    open = insert_activated_user(noindex?: false, noai?: false)

    md = get(build_conn(), "/#{open.username}.md").resp_body
    refute md =~ "noindex: true"
    refute md =~ "noai: true"
  end
end

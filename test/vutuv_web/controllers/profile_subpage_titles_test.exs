defmodule VutuvWeb.ProfileSubpageTitlesTest do
  @moduledoc """
  Every public /:slug subpage must title itself with the member's name plus
  its own section label. Before this, all section pages fell back to the bare
  member name — the exact `<title>` of the profile itself — so a member's own
  subpages competed with /:slug in search results (duplicate titles across
  the whole site), and the generic manage titles ("Experience - vutuv")
  collided across every member.
  """

  use VutuvWeb.ConnCase

  # Public profile section indexes + the three people lists. The posts archive
  # already titles itself ("Name · Posts", PostController).
  @sections ~w(work_experiences educations languages qualifications links
               social_media_accounts addresses phone_numbers emails tags
               followers following connections)

  test "every public subpage titles with the member's name and its own label", %{conn: conn} do
    user = insert_activated_user(first_name: "Tina", last_name: "Titles")

    titles =
      for section <- @sections do
        html = conn |> get("/#{user.username}/#{section}") |> html_response(200)
        title = extract_title(html)

        assert title =~ "Tina Titles",
               "#{section} page title #{inspect(title)} misses the member's name"

        refute title == "Tina Titles - vutuv",
               "#{section} page title is identical to the profile's own title"

        title
      end

    assert Enum.uniq(titles) == titles,
           "public subpage titles must be unique per page, got: #{inspect(titles)}"
  end

  test "the German render titles with the translated label, not an English island", %{conn: conn} do
    user = insert_activated_user(first_name: "Doro", last_name: "Deutsch")

    html =
      conn
      |> put_req_header("accept-language", "de-DE,de")
      |> get("/#{user.username}/work_experiences")
      |> html_response(200)

    title = extract_title(html)
    assert title =~ "Doro Deutsch"
    refute title == "Doro Deutsch - vutuv"
  end

  test "a section entry page titles with the entry, not just the section", %{conn: conn} do
    user = insert_activated_user(first_name: "Erik", last_name: "Entry")

    job =
      insert(:work_experience, user: user, title: "Staff Engineer", organization: "Acme Corp")

    html = conn |> get("/#{user.username}/work_experiences/#{job.slug}") |> html_response(200)

    assert extract_title(html) == "Erik Entry · Staff Engineer - vutuv"
  end

  defp extract_title(html) do
    [title] = Regex.run(~r|<title[^>]*>\s*(.*?)\s*</title>|s, html, capture: :all_but_first)
    title
  end
end

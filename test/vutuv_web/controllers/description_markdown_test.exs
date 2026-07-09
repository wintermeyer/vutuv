defmodule VutuvWeb.DescriptionMarkdownTest do
  @moduledoc """
  Issue #905: work-experience and education descriptions are user-written
  Markdown. They must render as real HTML (paragraphs, line breaks, bullet
  lists, bold) on the profile section pages and the single-entry show pages,
  not as a one-line blob of literal `**` / `-` source.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  @markdown "Led the **backend** team.\n\n- Scaled the API\n- Mentored juniors"

  describe "work experience description" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      work = insert(:work_experience, user: user, description: @markdown)
      %{conn: conn, user: user, work: work}
    end

    test "renders Markdown on the section list page", %{conn: conn, user: user} do
      body = conn |> get(~p"/#{user}/work_experiences") |> html_response(200)

      assert_markdown(body)
    end

    test "renders Markdown on the show page", %{conn: conn, user: user, work: work} do
      body = conn |> get(~p"/#{user}/work_experiences/#{work}") |> html_response(200)

      assert_markdown(body)
    end
  end

  describe "education description" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      education = insert(:education, user: user, description: @markdown)
      %{conn: conn, user: user, education: education}
    end

    test "renders Markdown on the section list page", %{conn: conn, user: user} do
      body = conn |> get(~p"/#{user}/educations") |> html_response(200)

      assert_markdown(body)
    end

    test "renders Markdown on the show page", %{conn: conn, user: user, education: education} do
      body = conn |> get(~p"/#{user}/educations/#{education}") |> html_response(200)

      assert_markdown(body)
    end
  end

  # The description is rendered, not shown as a one-line blob of source: the bold
  # span and the bullet list are real HTML, and the literal `**` / `-` markers
  # are gone.
  defp assert_markdown(body) do
    assert body =~ "<strong>backend</strong>"
    assert body =~ "<ul>"
    assert body =~ "Scaled the API"
    assert body =~ "Mentored juniors"
    refute body =~ "**backend**"
    refute body =~ "- Scaled the API"
  end
end

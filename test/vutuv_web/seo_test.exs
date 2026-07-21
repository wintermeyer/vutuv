defmodule VutuvWeb.SeoTest do
  use VutuvWeb.ConnCase, async: true

  # GEO/SEO hardening (see the heise "GEO und SEO" article analysis):
  #
  #   1. Heading hierarchy — every public page must have exactly ONE <h1>,
  #      with subsections as <h2>+. The tag page, the post permalink and the
  #      profile-section show pages used to violate this (multiple <h1>, or
  #      none at all).
  #   2. An explicit <link rel="canonical"> in the <head>, sharing its value
  #      with og:url (one chokepoint in VutuvWeb.OpenGraph). The canonical
  #      drops volatile query params (?lang, ?page) like og:url already does.

  alias VutuvWeb.Endpoint

  # Counts opening <h1> tags in a rendered page. JSON-LD lives in a
  # <script> block as JSON (no "<h1"), so it never produces a false match.
  defp h1_count(body), do: ~r/<h1[\s>]/i |> Regex.scan(body) |> length()

  defp canonical_href(body) do
    case Regex.run(~r/<link rel="canonical" href="([^"]*)"/, body) do
      [_, href] -> href
      _ -> nil
    end
  end

  describe "exactly one <h1> per public page" do
    test "profile page", %{conn: conn} do
      user = insert_activated_user()
      body = conn |> get(~p"/#{user}") |> html_response(200)
      assert h1_count(body) == 1
    end

    test "tag page (with a description and subsections)", %{conn: conn} do
      tag = insert(:tag, description: "The BEAM language.")
      body = conn |> get(~p"/tags/#{tag}") |> html_response(200)
      assert h1_count(body) == 1
    end

    test "post permalink", %{conn: conn} do
      author = insert_activated_user()
      post = Vutuv.PostsHelpers.create_post!(author, %{body: "Hello world"})
      body = conn |> get(Vutuv.Posts.path(post)) |> html_response(200)
      assert h1_count(body) == 1
    end

    test "profile-section show page (work experience with a description)", %{conn: conn} do
      user = insert_activated_user()

      job =
        insert(:work_experience,
          user: user,
          title: "Engineer",
          organization: "Acme",
          description: "Built things."
        )

      body = conn |> get(~p"/#{user}/work_experiences/#{job}") |> html_response(200)
      assert h1_count(body) == 1
    end
  end

  describe "explicit <link rel=\"canonical\">" do
    test "profile canonical is the absolute profile URL", %{conn: conn} do
      user = insert_activated_user()
      body = conn |> get(~p"/#{user}") |> html_response(200)
      assert canonical_href(body) == Endpoint.url() <> "/#{user.username}"
    end

    test "the ?lang query is dropped from the canonical", %{conn: conn} do
      user = insert_activated_user()
      body = conn |> get("/#{user.username}?lang=de") |> html_response(200)
      assert canonical_href(body) == Endpoint.url() <> "/#{user.username}"
    end

    test "post permalink canonical is the absolute permalink", %{conn: conn} do
      author = insert_activated_user()
      post = Vutuv.PostsHelpers.create_post!(author, %{body: "Hello world"})
      body = conn |> get(Vutuv.Posts.path(post)) |> html_response(200)
      assert canonical_href(body) == Endpoint.url() <> Vutuv.Posts.path(post)
    end

    test "home page canonical keeps the root slash", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert canonical_href(body) == Endpoint.url() <> "/"
    end
  end
end

defmodule VutuvWeb.ProfileCvPreviewTest do
  @moduledoc """
  How much of a CV the profile's Lebenslauf and Ausbildung cards preview.

  Both used to spend ONE budget over every category, newest entry first, so
  whichever category sorted last was starved: a member with a dozen Ehrenämter
  saw two jobs, and a member whose three newest rows were all Hochschulbildung
  lost their Ausbildung from the card outright, heading and all. Education's cut
  happened in SQL (`limit:` on the preload), before the grouping could see the
  list, which is why that half has to be tested through a rendered page rather
  than through the view module.
  """
  use VutuvWeb.ConnCase, async: true

  defp profile(conn, user, opts \\ []) do
    conn
    |> put_req_header("accept-language", Keyword.get(opts, :locale, "en"))
    |> get(~p"/#{user}")
    |> html_response(200)
  end

  describe "a category the newest entries crowd out" do
    test "keeps its place on the Ausbildung card", %{conn: conn} do
      user = insert_activated_user()

      # The newest three rows are all Hochschulbildung, so a cut of three taken
      # before the grouping leaves nothing for the Ausbildung heading to hold.
      for year <- [2024, 2020, 2016] do
        insert(:education, user: user, kind: "university", school: "Uni #{year}", end_year: year)
      end

      insert(:education,
        user: user,
        kind: "apprenticeship",
        school: "IHK Koblenz",
        end_year: 2012
      )

      html = profile(conn, user)

      assert html =~ "IHK Koblenz"
      assert html =~ "Vocational Training"
    end

    test "keeps its place on the Lebenslauf card", %{conn: conn} do
      user = insert_activated_user()

      for year <- [2026, 2025, 2024, 2023, 2022, 2021, 2020, 2019, 2018, 2017] do
        insert(:work_experience,
          user: user,
          kind: "volunteer",
          organization: "Verein #{year}",
          start_year: year
        )
      end

      insert(:work_experience,
        user: user,
        kind: "employment",
        organization: "Acme GmbH",
        start_year: 2001,
        end_year: 2010
      )

      html = profile(conn, user)

      assert html =~ "Acme GmbH"
      assert html =~ "Professional Experience"
    end
  end

  describe "the note under a truncated category" do
    test "counts the hidden entries and names the years they cover", %{conn: conn} do
      user = insert_activated_user()

      for year <- [2024, 2020, 2016, 2008, 2004] do
        insert(:education,
          user: user,
          kind: "university",
          school: "Uni #{year}",
          start_year: year - 3,
          end_year: year
        )
      end

      html = profile(conn, user)

      # Three shown, two hidden, spanning the earliest start to the latest end
      # among the hidden pair.
      assert html =~ "2 more entries (2001 - 2008)"
      assert html =~ ~s(href="/#{user.username}/educations")
    end

    test "reads in German for a German visitor", %{conn: conn} do
      user = insert_activated_user()

      for year <- [2024, 2020, 2016, 2008] do
        insert(:education,
          user: user,
          kind: "university",
          school: "Uni #{year}",
          start_year: year - 3,
          end_year: year
        )
      end

      html = profile(conn, user, locale: "de-DE,de;q=0.9")

      assert html =~ "Ein weiterer Eintrag (2005 - 2008)"
    end

    test "stays away while the category fits", %{conn: conn} do
      user = insert_activated_user()
      insert(:education, user: user, kind: "university", school: "Uni Trier", end_year: 2010)

      html = profile(conn, user)

      refute html =~ "more entries"
      refute html =~ "One more entry"
    end
  end

  describe "the category headings" do
    test "link to the section that holds the rest", %{conn: conn} do
      user = insert_activated_user()
      insert(:work_experience, user: user, kind: "employment", organization: "Acme GmbH")
      insert(:work_experience, user: user, kind: "volunteer", organization: "Chor Trier")
      insert(:education, user: user, kind: "university", school: "Uni Trier")
      insert(:education, user: user, kind: "school", school: "Gymnasium Trier")

      html = profile(conn, user)

      assert html =~
               ~r{<a href="/#{user.username}/work_experiences"[^>]*>\s*Professional Experience}

      assert html =~ ~r{<a href="/#{user.username}/educations"[^>]*>\s*Higher Education}
    end
  end
end

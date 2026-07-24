defmodule VutuvWeb.CVLiveTest do
  @moduledoc """
  The interactive CV builder (issue #841): toggling a section, entry or
  identity field updates the download links so every export reflects the
  current selection; "Anonymize" hides the name/photo/contact in one click.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias VutuvWeb.CVLive

  defp seed(user) do
    insert(:work_experience,
      user: user,
      title: "Senior Developer",
      organization: "ACME GmbH",
      kind: "employment",
      description: "**Led** the team\n\n- shipped things",
      start_year: 2020
    )

    insert(:work_experience,
      user: user,
      title: "Werkstudent",
      organization: "Beispiel AG",
      kind: "internship",
      start_year: 2018,
      end_year: 2019
    )

    insert(:education, user: user, school: "Universität Bremen", degree: "BSc", start_year: 2014)
    insert(:language, user: user, language_code: "en", proficiency: "c2")
    insert(:qualification, user: user, name: "AWS Certified Solutions Architect")
    insert(:social_media_account, user: user, provider: "GitHub", value: "octocat")
    user
  end

  defp owner(_context) do
    user =
      seed(
        insert(:user,
          first_name: "Erika",
          last_name: "Beispiel",
          email_confirmed?: true,
          birthdate: ~D[1990-05-15],
          gender: "female"
        )
      )

    %{owner: user}
  end

  describe "the builder page" do
    setup :owner

    test "renders the controls and the download panel", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(conn, ~p"/#{owner}/cv")

      assert has_element?(view, "#cv-anonymize")
      assert has_element?(view, "#cv-reset")
      assert has_element?(view, "#cv-print")
      assert has_element?(view, "#cv-download-docx")
      assert has_element?(view, "#cv-download-json")
      # The full CV downloads carry no ?hide= until something is unticked.
      assert has_element?(view, "#cv-download-docx[href='/#{owner.username}/cv/download/docx']")
    end

    test "the entry hint shows the description without Markdown markers", %{
      conn: conn,
      owner: owner
    } do
      {:ok, _view, html} = live(conn, ~p"/#{owner}/cv")

      # The checklist hint is one truncated line of plain text (issue #920).
      assert html =~ "Led the team"
      refute html =~ "**Led**"
    end

    test "unticking a section encodes it into every download link", %{conn: conn, owner: owner} do
      internship = Repo.get_by(WorkExperience, title: "Werkstudent", user_id: owner.id)
      {:ok, view, _html} = live(conn, ~p"/#{owner}/cv")

      # A single entry (the internship) has its own toggle.
      assert has_element?(view, "input[phx-value-key='#{internship.id}']")

      # Hide the whole internship section (key "internship").
      view |> element("input[phx-value-key='internship']") |> render_click()

      assert has_element?(view, "#cv-download-docx[href*='hide=internship']")
      assert has_element?(view, "#cv-print[href*='hide=internship']")
    end

    test "offers toggles for the newer sections and personal details", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(conn, ~p"/#{owner}/cv")

      # Sections added after the CV shipped each get their own toggle card.
      assert has_element?(view, "input[phx-value-key='languages']")
      assert has_element?(view, "input[phx-value-key='qualifications']")
      assert has_element?(view, "input[phx-value-key='social_media']")
      # Date of birth and gender ride in the header identity toggles.
      assert has_element?(view, "input[phx-value-key='birthdate']")
      assert has_element?(view, "input[phx-value-key='gender']")

      # Unticking one encodes it into every download link.
      view |> element("input[phx-value-key='social_media']") |> render_click()
      assert has_element?(view, "#cv-download-docx[href*='hide=social_media']")
    end

    test "the JSON Resume explainer links to jsonresume.org (#862)", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(conn, ~p"/#{owner}/cv")

      # The download hint names "jsonresume.org" — it must be a real link so a
      # reader can reach the format's home, not bare text to retype.
      assert has_element?(view, "a[href='https://jsonresume.org']", "jsonresume.org")
    end

    test "Anonymize hides the identity fields in the download links", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(conn, ~p"/#{owner}/cv")

      view |> element("#cv-anonymize") |> render_click()

      assert has_element?(view, "#cv-download-docx[href*='hide=']")
      assert has_element?(view, "#cv-download-docx[href*='name']")
      assert has_element?(view, "#cv-download-docx[href*='photo']")

      # Reset clears the selection: the links go back to the full CV.
      view |> element("#cv-reset") |> render_click()
      assert has_element?(view, "#cv-download-docx[href='/#{owner.username}/cv/download/docx']")
    end
  end

  describe "the JSON Resume download" do
    test "is offered for a machine-opted-out member too", %{conn: conn} do
      # The JSON Resume is a member-initiated CV export of the same public CV
      # as every other format, so the agent-doc opt-out no longer hides it.
      owner = seed(insert(:user, email_confirmed?: true, noindex?: true, noai?: true))

      {:ok, view, _html} = live(conn, ~p"/#{owner}/cv")

      assert has_element?(view, "#cv-download-docx")
      assert has_element?(view, "#cv-download-json")
    end
  end

  # The CV page is public (no login), so a raw phx "toggle" event — bypassing
  # the rendered checkboxes — must not let a client store arbitrary strings in
  # the socket's :hide set and re-sort/re-join them into six download hrefs on
  # every event (F12: an unbounded-accumulation DoS).
  describe "the toggle event is hardened against arbitrary client keys (F12)" do
    setup :owner

    test "a toggle for a key the CV does not offer is ignored", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(conn, ~p"/#{owner}/cv")

      # Baseline: the full CV downloads carry no ?hide=.
      assert has_element?(view, "#cv-download-docx[href='/#{owner.username}/cv/download/docx']")

      # A raw phx event carrying an arbitrary multi-KB key is a no-op: nothing is
      # stored, the query is unchanged, so no download link gains a ?hide=.
      render_hook(view, "toggle", %{"key" => String.duplicate("x", 5_000)})

      assert has_element?(view, "#cv-download-docx[href='/#{owner.username}/cv/download/docx']")
      refute has_element?(view, "#cv-download-docx[href*='hide=']")
    end

    test "a toggle for a real CV key still toggles it", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(conn, ~p"/#{owner}/cv")

      render_hook(view, "toggle", %{"key" => "name"})
      assert has_element?(view, "#cv-download-docx[href*='hide=name']")
    end
  end

  describe "apply_toggle/3 (the pure toggle core)" do
    test "ignores a key the CV does not offer" do
      allowed = MapSet.new(["name", "photo"])
      assert CVLive.apply_toggle(MapSet.new(), "bogus", allowed) == MapSet.new()
    end

    test "flips an offered key on and back off" do
      allowed = MapSet.new(["name"])

      on = CVLive.apply_toggle(MapSet.new(), "name", allowed)
      assert MapSet.member?(on, "name")

      off = CVLive.apply_toggle(on, "name", allowed)
      refute MapSet.member?(off, "name")
    end

    test "refuses to grow the hide set past the cap" do
      # 600 legitimate keys on offer, but the set can never hold more than 500.
      allowed = MapSet.new(for i <- 0..599, do: "k#{i}")

      full =
        Enum.reduce(0..599, MapSet.new(), fn i, acc ->
          CVLive.apply_toggle(acc, "k#{i}", allowed)
        end)

      assert MapSet.size(full) == 500

      # A further offered, not-yet-hidden key is refused once the cap is hit...
      next = Enum.find(0..599, fn i -> not MapSet.member?(full, "k#{i}") end)
      assert CVLive.apply_toggle(full, "k#{next}", allowed) == full

      # ...but removing an already-hidden key still works at the cap.
      [some | _] = MapSet.to_list(full)
      refute MapSet.member?(CVLive.apply_toggle(full, some, allowed), some)
    end
  end
end

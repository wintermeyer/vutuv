defmodule VutuvWeb.JobPostingTest do
  @moduledoc """
  The job-posting web layer (issue #932): the editor LiveView, the public detail
  page, the machine-visibility gating (seo?/geo?/members), the report → freeze
  path and easy apply.
  """

  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.JobsHelpers

  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPostingImage
  alias Vutuv.Repo

  # Age the logged-in account past the 3-day publish gate.
  defp age_account(user) do
    old = NaiveDateTime.add(NaiveDateTime.utc_now(), -5 * 86_400, :second)

    Repo.update_all(from(u in Vutuv.Accounts.User, where: u.id == ^user.id),
      set: [inserted_at: old]
    )
  end

  defp form_params(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => "Platform Engineer (m/w/d)",
        "employment_type" => "full_time",
        "workplace_type" => "onsite",
        "zip_code" => "50667",
        "city" => "Köln",
        "country" => "DE",
        "salary_min" => "60000",
        "salary_max" => "80000",
        "salary_currency" => "EUR",
        "salary_period" => "year",
        "apply_kind" => "message",
        "language" => "de",
        "visibility" => "everyone",
        "required_tags" => "Elixir",
        "nice_to_have_tags" => "Kubernetes"
      },
      overrides
    )
  end

  describe "editor" do
    test "the new-posting form renders with a real submit action", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, _view, html} = live(conn, ~p"/jobs/new")
      assert html =~ ~s(id="job-posting-form")
      assert html =~ "Publish"
    end

    test "publishing without a salary range is rejected inline", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      age_account(user)
      {:ok, view, _html} = live(conn, ~p"/jobs/new")

      html =
        view
        |> form("#job-posting-form",
          job_posting: form_params(%{"salary_min" => "", "salary_max" => ""})
        )
        |> render_submit(%{"do" => "publish"})

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "a complete posting publishes and lands on the public page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      age_account(user)
      {:ok, view, _html} = live(conn, ~p"/jobs/new")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("#job-posting-form", job_posting: form_params())
        |> render_submit(%{"do" => "publish"})

      assert to =~ "/jobs/"
      slug = to |> String.split("/") |> List.last()
      posting = Jobs.get_job_posting_by_slug(slug)
      assert posting.status == :published
      assert posting.lat && posting.lon
      assert Enum.map(Jobs.tags_of(posting, :required), & &1.name) == ["Elixir"]
    end

    test "removing an already-attached image does not crash the editor", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, posting} = Jobs.create_draft(user, %{"title" => "Draft"})

      image =
        Repo.insert!(%JobPostingImage{
          job_posting_id: posting.id,
          user_id: user.id,
          token: JobPostingImage.gen_token(),
          width: 800,
          height: 600,
          content_type: "image/avif",
          size_bytes: 1234
        })

      {:ok, view, _html} = live(conn, ~p"/jobs/#{posting.slug}/edit")
      # Pre-fix this raised FunctionClauseError (delete_pending_image only
      # matched pending images) and crashed the editor socket.
      assert render_click(view, "remove-image", %{"id" => image.id})
      refute render(view) =~ image.token
    end
  end

  # Form params for a remote posting. The address block is gone from the DOM
  # once the workplace is remote, and `form/3` refuses to fill a field the
  # rendered form does not have.
  defp remote_params(overrides \\ %{}) do
    overrides
    |> Map.put("workplace_type", "remote")
    |> form_params()
    |> Map.drop(["zip_code", "city", "country"])
  end

  # Switch the workplace to remote so the applicant-country picker renders, and
  # hand back the HTML it produced.
  defp go_remote(view) do
    view
    |> form("#job-posting-form", job_posting: form_params(%{"workplace_type" => "remote"}))
    |> render_change()
  end

  describe "applicant countries (issues #1558, #1559)" do
    test "the picker shows the chosen countries as pills, never a 249-row select",
         %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, view, _html} = live(conn, ~p"/jobs/new")

      html = go_remote(view)

      # The whole point of #1558: the old control hid the selection.
      refute html =~ ~s(id="job_posting_remote_countries")
      refute html =~ "Hold Ctrl"
      # Switching to remote preselects the installation's own country, visibly
      # (the test conn speaks English, so the pill reads "Germany").
      assert html =~ "Germany"
      assert html =~ ~s(name="job_posting[remote_countries][]" value="DE")

      html = render_click(view, "country-add", %{"code" => "AT"})
      assert html =~ ~s(name="job_posting[remote_countries][]" value="AT")

      html = render_click(view, "country-remove", %{"code" => "DE"})
      refute html =~ ~s(name="job_posting[remote_countries][]" value="DE")
      assert html =~ ~s(name="job_posting[remote_countries][]" value="AT")
    end

    test "an emptied list stays empty across the next form change", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, view, _html} = live(conn, ~p"/jobs/new")

      go_remote(view)
      render_click(view, "country-clear", %{})

      # The seed must fire only the first time the field appears. Typing on in
      # the form re-sends the (now empty) field, and putting Germany back would
      # overrule an answer the member gave on purpose.
      html =
        view
        |> form("#job-posting-form", job_posting: remote_params(%{"title" => "Remote Role"}))
        |> render_change()

      refute html =~ ~s(name="job_posting[remote_countries][]" value="DE")
      assert html =~ "No country chosen yet."
    end

    test "the search box finds a country and adding one drops it from the hits",
         %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, view, _html} = live(conn, ~p"/jobs/new")
      go_remote(view)

      html = render_change(view, "country-search", %{"country_query" => "witzerl"})
      assert html =~ "Switzerland"
      assert html =~ ~s(phx-click="country-add" phx-value-code="CH")

      # Enter in the box takes the top hit (the sibling form's phx-submit), so
      # it can never publish the posting half-finished.
      html = render_submit(view, "country-add-first", %{})
      assert html =~ ~s(name="job_posting[remote_countries][]" value="CH")
      # Offered once, then it is a pill — a hit you have already taken would
      # answer a tap with nothing visibly happening.
      refute html =~ ~s(phx-click="country-add" phx-value-code="CH")
    end

    test "a region preset fills in its whole expansion and publishes with it",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      age_account(user)
      {:ok, view, _html} = live(conn, ~p"/jobs/new")
      go_remote(view)

      render_click(view, "country-clear", %{})
      render_click(view, "country-region", %{"region" => "EU"})

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("#job-posting-form", job_posting: remote_params())
        |> render_submit(%{"do" => "publish"})

      posting = Jobs.get_job_posting_by_slug(to |> String.split("/") |> List.last())
      # The expansion is what gets stored, so Jobs.filter_location/4 keeps
      # working against remote_countries untouched (issue #1559).
      assert Enum.sort(posting.remote_countries) == Vutuv.Countries.region_codes("EU")
      assert length(posting.remote_countries) == 27
    end

    test "a whole region reads as its name on the card and the detail page" do
      posting =
        publish_job!(nil, %{
          "workplace_type" => "remote",
          "remote_countries" => Vutuv.Countries.region_codes("EU")
        })

      assert VutuvWeb.JobComponents.card_location(posting) =~ "(EU)"

      assert VutuvWeb.JobComponents.remote_countries_label(posting.remote_countries, :name) ==
               "EU"
    end

    test "the picker speaks German to a German browser", %{conn: conn} do
      # `mix gettext.extract --merge` fuzzy-filled every one of these labels
      # with an unrelated translation ("Land suchen" arrived as "Konto zum
      # Einfrieren suchen"), and nothing in the build says so.
      {conn, user} = create_and_login_user(conn)
      user |> Ecto.Changeset.change(%{locale: nil}) |> Repo.update!()

      {:ok, view, _html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> live(~p"/jobs/new")

      html = go_remote(view)
      assert html =~ "Land suchen"
      assert html =~ "1 Land ausgewählt."
      assert html =~ "Alle entfernen"
      assert html =~ "Deutschland entfernen"

      assert render_click(view, "country-clear", %{}) =~ "Noch kein Land ausgewählt."
    end

    test "a long selection is capped instead of spelling out every country" do
      # 128 codes in a card chip is not a chip.
      label = VutuvWeb.JobComponents.remote_countries_label(~w(DE AT CH FR IT), :code)
      assert label == "DE, AT, CH +2 more"
    end
  end

  describe "detail page + gating" do
    test "a public posting shows salary, employer and JSON-LD with validThrough", %{conn: conn} do
      posting = publish_job!()
      html = conn |> get(~p"/jobs/#{posting.slug}") |> html_response(200)

      assert html =~ "JobPosting"
      assert html =~ "validThrough"
      assert html =~ Date.to_iso8601(posting.expires_on)
      assert html =~ "€"
    end

    test "seo? off removes the JSON-LD and the sitemap entry", %{conn: conn} do
      posting = publish_job!()
      {:ok, _} = posting |> Ecto.Changeset.change(seo?: false) |> Repo.update()

      html = conn |> get(~p"/jobs/#{posting.slug}") |> html_response(200)
      refute html =~ "JobPosting"

      refute Enum.any?(Vutuv.Sitemap.job_entries(1), fn {path, _} -> path =~ posting.slug end)
    end

    test "geo? off 404s the agent siblings but still renders HTML", %{conn: conn} do
      posting = publish_job!()
      {:ok, _} = posting |> Ecto.Changeset.change(geo?: false) |> Repo.update()

      assert conn |> get(~p"/jobs/#{posting.slug}") |> html_response(200)
      assert conn |> get("/jobs/#{posting.slug}.md") |> response(404)
    end

    test "a members-only posting 404s for a logged-out visitor", %{conn: conn} do
      posting = publish_job!()
      {:ok, _} = posting |> Ecto.Changeset.change(visibility: :members) |> Repo.update()

      assert conn |> get(~p"/jobs/#{posting.slug}") |> response(404)
    end
  end

  describe "report → freeze" do
    test "a report from a member in good standing freezes the posting for the public", %{
      conn: conn
    } do
      posting = publish_job!()
      {reporter_conn, _reporter} = create_and_login_user(conn)

      reporter_conn
      |> get(~p"/reports/new?#{[type: "job_posting", id: posting.id]}")
      |> submit_with_csrf(~p"/reports", %{
        "report" => %{"type" => "job_posting", "id" => posting.id, "category" => "misleading_job"}
      })

      assert Repo.reload!(posting).frozen_at

      # Frozen: a logged-out visitor now gets a 404, not the page.
      assert build_conn() |> get(~p"/jobs/#{posting.slug}") |> response(404)
    end

    test "the owner can delete a frozen reported posting, settling the case" do
      owner = poster_fixture()
      posting = publish_job!(owner)
      reporter = insert(:activated_user)

      {:ok, case_record} =
        Vutuv.Moderation.report_content(reporter, posting, %{"category" => "misleading_job"})

      # Pre-fix delete_reported_content had no %JobPosting{} branch -> CaseClauseError 500.
      assert :ok = Vutuv.Moderation.delete_reported_content(case_record, owner)
      refute Jobs.get_job_posting(posting.id)
      assert Repo.reload!(case_record).status == "resolved_deleted"
    end

    test "the owner editing a frozen reported posting lifts the freeze and settles the case" do
      owner = poster_fixture()
      posting = publish_job!(owner)
      reporter = insert(:activated_user)

      {:ok, case_record} =
        Vutuv.Moderation.report_content(reporter, posting, %{"category" => "misleading_job"})

      assert Repo.reload!(posting).frozen_at

      {:ok, _} = Jobs.update_posting(Repo.reload!(posting), owner, %{"title" => "Revised title"})

      refute Repo.reload!(posting).frozen_at
      assert Repo.reload!(case_record).status == "resolved_edited"
    end
  end

  describe "apply" do
    test "message apply increments the click count and opens a conversation", %{conn: conn} do
      posting = publish_job!()
      {applicant_conn, _applicant} = create_and_login_user(conn)

      applied = post(applicant_conn, ~p"/jobs/#{posting.slug}/apply")
      assert redirected_to(applied) =~ "/messages/with/"
      assert Repo.reload!(posting).apply_click_count == 1
    end
  end
end

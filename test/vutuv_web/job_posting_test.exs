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

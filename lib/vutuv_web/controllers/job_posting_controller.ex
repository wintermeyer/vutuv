defmodule VutuvWeb.JobPostingController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.AuthRecruiter when action in [:edit, :update, :new, :create, :delete])
  plug(:validate_recruiter)

  plug(VutuvWeb.Plug.ResolveSlug,
    slug: "job_slug",
    model: Vutuv.JobPostings.JobPosting,
    assign: :job_posting,
    field: :slug
  )

  plug(:validate_package when action in [:new, :create, :index])

  alias Vutuv.JobPostings.JobPosting
  alias Vutuv.Recruiting.RecruiterSubscription

  def index(conn, _params) do
    user = Repo.preload(conn.assigns[:user], :job_postings)
    render(conn, "index.html", job_postings: user.job_postings)
  end

  def new(conn, _params) do
    today = Date.utc_today()
    {{current_year, current_month, current_day}, {_hour, _min, _sec}} = :erlang.localtime()

    {year, month, day} =
      :calendar.gregorian_days_to_date(
        :calendar.date_to_gregorian_days({current_year, current_month, current_day}) + 90
      )

    in_nity_days = Date.new!(year, month, day)

    changeset = JobPosting.changeset(%JobPosting{open_on: today, closed_on: in_nity_days})
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"job_posting" => job_posting_params}) do
    changeset =
      conn.assigns[:user]
      |> Ecto.build_assoc(:job_postings)
      |> JobPosting.changeset(job_posting_params)

    case Repo.insert(changeset) do
      {:ok, _job_posting} ->
        conn
        |> put_flash(:info, gettext("Job posting created successfully."))
        |> redirect(to: ~p"/users/#{conn.assigns[:user]}/job_postings")

      {:error, changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def show(conn, _params) do
    job_posting =
      conn.assigns[:job_posting]
      |> Repo.preload(job_posting_tags: :tag)

    render(conn, "show.html", job_posting: job_posting)
  end

  def edit(conn, _params) do
    job_posting = conn.assigns[:job_posting]
    changeset = JobPosting.changeset(job_posting)
    render(conn, "edit.html", job_posting: job_posting, changeset: changeset)
  end

  def update(conn, %{"job_posting" => job_posting_params}) do
    job_posting = conn.assigns[:job_posting]
    changeset = JobPosting.changeset(job_posting, job_posting_params)

    case Repo.update(changeset) do
      {:ok, job_posting} ->
        conn
        |> put_flash(:info, gettext("Job posting updated successfully."))
        |> redirect(to: ~p"/users/#{conn.assigns[:user]}/job_postings/#{job_posting}")

      {:error, changeset} ->
        render(conn, "edit.html", job_posting: job_posting, changeset: changeset)
    end
  end

  def delete(conn, _params) do
    job_posting = conn.assigns[:job_posting]

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(job_posting)

    conn
    |> put_flash(:info, gettext("Job posting deleted successfully."))
    |> redirect(to: ~p"/users/#{conn.assigns[:user]}/job_postings")
  end

  defp validate_recruiter(conn, _opts) do
    case RecruiterSubscription.active_subscription(conn.assigns[:user_id]) do
      nil ->
        conn
        |> put_status(403)
        |> put_view(html: VutuvWeb.ErrorHTML)
        |> render("403.html")
        |> halt

      subscription ->
        assign(conn, :active_subscription, subscription)
    end
  end

  defp validate_package(conn, _opts) do
    user = Repo.preload(conn.assigns[:user], [:job_postings])

    if Enum.count(user.job_postings) >=
         conn.assigns[:active_subscription].recruiter_package.max_job_postings do
      conn
      |> put_flash(
        :info,
        "You have reached your limit for posting jobs. If you wish to post a new job, you must delete an existing one or upgrade your plan."
      )
      |> render("index.html", job_postings: user.job_postings)
      |> halt
    else
      conn
    end
  end
end

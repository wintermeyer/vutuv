defmodule VutuvWeb.JobPostingTagController do
  use VutuvWeb, :controller

  # Gate writes the same way the parent JobPostingController does: only the
  # logged-in owner with a paid recruiter subscription may add/remove tags.
  # :index/:show stay public intentionally.
  plug(VutuvWeb.Plug.AuthRecruiter when action in [:new, :create, :delete])

  # Scope the job posting to the path user instead of resolving its globally
  # unique slug on its own. Otherwise a paid recruiter could pass their own
  # user slug together with another user's posting slug and tag a posting they
  # do not own.
  plug(:resolve_job_posting)

  plug(:resolve_slug)

  alias Vutuv.JobPostings.JobPostingTag
  alias Vutuv.Tags.Tag

  def index(conn, _params) do
    job_posting =
      conn.assigns[:job_posting]
      |> Repo.preload(job_posting_tags: :tag)

    render(conn, "index.html", job_posting_tags: job_posting.job_posting_tags)
  end

  def new(conn, _params) do
    changeset = JobPostingTag.changeset(%JobPostingTag{})
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"job_posting_tag" => job_posting_tag_params}) do
    changeset =
      conn.assigns[:job_posting]
      |> Ecto.build_assoc(:job_posting_tags)
      |> JobPostingTag.changeset(job_posting_tag_params)
      |> Tag.create_or_link_tag(job_posting_tag_params)

    case Repo.insert(changeset) do
      {:ok, _job_posting_tag} ->
        conn
        |> put_flash(:info, gettext("Job posting tag created successfully."))
        |> redirect(
          to: ~p"/users/#{conn.assigns[:user]}/job_postings/#{conn.assigns[:job_posting]}/tags"
        )

      {:error, changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def show(conn, _params) do
    job_posting_tag =
      conn.assigns[:job_posting_tag]
      |> Repo.preload([:tag])

    render(conn, "show.html", job_posting_tag: job_posting_tag)
  end

  def delete(conn, _params) do
    job_posting_tag = conn.assigns[:job_posting_tag]

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(job_posting_tag)

    conn
    |> put_flash(:info, gettext("Job posting tag deleted successfully."))
    |> redirect(
      to: ~p"/users/#{conn.assigns[:user]}/job_postings/#{conn.assigns[:job_posting]}/tags"
    )
  end

  defp resolve_job_posting(%{params: %{"job_posting_job_slug" => slug}} = conn, _) do
    Repo.one(
      from(j in Vutuv.JobPostings.JobPosting,
        where: j.slug == ^slug and j.user_id == ^conn.assigns[:user_id]
      )
    )
    |> case do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(html: VutuvWeb.ErrorHTML)
        |> render("404.html")
        |> halt()

      job_posting ->
        assign(conn, :job_posting, job_posting)
    end
  end

  defp resolve_job_posting(conn, _) do
    conn
    |> put_status(:not_found)
    |> put_view(html: VutuvWeb.ErrorHTML)
    |> render("404.html")
    |> halt()
  end

  defp resolve_slug(%{params: %{"id" => slug}} = conn, _) do
    Repo.one(
      from(w in assoc(conn.assigns[:job_posting], :job_posting_tags),
        join: t in assoc(w, :tag),
        where: t.slug == ^slug
      )
    )
    |> case do
      nil ->
        conn
        |> put_status(404)
        |> put_view(html: VutuvWeb.ErrorHTML)
        |> render("404.html")
        |> halt()

      job_posting_tag ->
        assign(conn, :job_posting_tag, job_posting_tag)
    end
  end

  defp resolve_slug(conn, _), do: conn
end

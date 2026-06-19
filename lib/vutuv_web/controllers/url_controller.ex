defmodule VutuvWeb.UrlController do
  use VutuvWeb, :controller
  alias Vutuv.Profiles.Url
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "url" when action in [:create, :update])

  # Index and show are also served as Markdown / text / JSON via
  # VutuvWeb.AgentDocs.SectionDocs (see agent_docs_drift_test.exs).
  def index(conn, _params) do
    urls = Repo.all(Url.ordered(assoc(conn.assigns[:user], :urls)))

    AgentDocs.respond(conn,
      html: fn conn ->
        conn
        |> VutuvWeb.ViewAs.assign_preview()
        |> render("index.html", urls: urls)
      end,
      doc: fn -> SectionDocs.build_index(conn.assigns[:user], :links, urls) end
    )
  end

  def new(conn, _params) do
    changeset =
      conn.assigns[:user]
      |> build_assoc(:urls)
      |> Url.changeset()

    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"url" => url_params}) do
    user = conn.assigns[:user]

    changeset =
      user
      # New links land at the end of the owner's chosen order. `position` is set
      # on the struct (not cast) so a forged `url[position]` param can't move it.
      # Reordering itself lives in VutuvWeb.SectionReorderLive via Vutuv.Ordering.
      |> build_assoc(:urls, position: Vutuv.Ordering.next_position(Url, user.id))
      |> Url.changeset(url_params)

    case Repo.insert(changeset) do
      {:ok, url} ->
        generate_screenshot(url)

        conn
        |> put_flash(:info, gettext("Link created successfully."))
        |> redirect(to: ~p"/#{conn.assigns[:user]}/links")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render("new.html", changeset: changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    url = ControllerHelpers.get_owned!(conn, :urls, id)

    AgentDocs.respond(conn,
      html: &render(&1, "show.html", url: url),
      doc: fn -> SectionDocs.build_show(conn.assigns[:user], :links, url) end
    )
  end

  def edit(conn, %{"id" => id}) do
    url = ControllerHelpers.get_owned!(conn, :urls, id)
    changeset = Url.changeset(url)
    render(conn, "edit.html", url: url, changeset: changeset)
  end

  def update(conn, %{"id" => id, "url" => url_params}) do
    url = ControllerHelpers.get_owned!(conn, :urls, id)
    changeset = Url.changeset(url, url_params)

    case Repo.update(changeset) do
      {:ok, url} ->
        generate_screenshot(url)

        conn
        |> put_flash(:info, gettext("Link updated successfully."))
        |> redirect(to: ~p"/#{conn.assigns[:user]}/links/#{url}")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render("edit.html", url: url, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    url = ControllerHelpers.get_owned!(conn, :urls, id)
    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).

    Repo.delete!(url)

    conn
    |> put_flash(:info, gettext("Link deleted successfully."))
    |> redirect(to: ~p"/#{conn.assigns[:user]}/links")
  end

  # Capture the page screenshot off the request path. Supervised by
  # Vutuv.TaskSupervisor (rather than an orphaned `Task.start/3`) so the work
  # has supervision and is not silently dropped on a node restart mid-request.
  # Gated by `:generate_screenshots` so tests neither launch headless Chromium
  # nor touch the SQL Sandbox connection from an unrelated process.
  defp generate_screenshot(url) do
    if Application.get_env(:vutuv, :generate_screenshots, true) do
      Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn ->
        Vutuv.PageScreenshot.generate_screenshot(url)
      end)
    end

    :ok
  end
end

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
      |> build_assoc(:urls, position: next_position(user))
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

  # Drag-and-drop reorder: the page sends the full list of link ids in their new
  # order. We renumber only the owner's own links (a forged or stale foreign id
  # is dropped), append any the client didn't mention, and answer 204 — the JS
  # has already moved the rows, so there is nothing to re-render.
  def reorder(conn, %{"order" => order}) when is_list(order) do
    user = conn.assigns[:user]
    owned = owned_ids(user)
    owned_set = MapSet.new(owned)

    submitted = order |> Enum.filter(&MapSet.member?(owned_set, &1)) |> Enum.uniq()
    remaining = Enum.reject(owned, &(&1 in submitted))

    persist_order(user, submitted ++ remaining)
    send_resp(conn, :no_content, "")
  end

  def reorder(conn, _params), do: send_resp(conn, :bad_request, "")

  # Nudge one link up or down by a single step — the no-JS, keyboard-friendly
  # fallback for the drag-and-drop tool. We swap the link with its neighbour in
  # the current order and renumber, so positions stay a clean 1..n.
  def move(conn, %{"id" => id, "direction" => direction}) when direction in ["up", "down"] do
    user = conn.assigns[:user]

    user
    |> owned_ids()
    |> swap(id, direction)
    |> then(&persist_order(user, &1))

    redirect(conn, to: ~p"/#{user}/links")
  end

  # The owner's link ids in the current display order.
  defp owned_ids(user) do
    Repo.all(from(u in Url.ordered(assoc(user, :urls)), select: u.id))
  end

  defp swap(ids, id, direction) do
    case Enum.find_index(ids, &(&1 == id)) do
      nil ->
        ids

      idx ->
        target = if direction == "up", do: idx - 1, else: idx + 1

        if target in 0..(length(ids) - 1) do
          ids
          |> List.replace_at(idx, Enum.at(ids, target))
          |> List.replace_at(target, Enum.at(ids, idx))
        else
          ids
        end
    end
  end

  # Write positions 1..n for the given ids, scoped to the owner so a stray id
  # can never touch another member's row. One transaction keeps the order
  # consistent if a write fails midway.
  defp persist_order(user, ordered_ids) do
    Repo.transaction(fn ->
      ordered_ids
      |> Enum.with_index(1)
      |> Enum.each(fn {id, position} ->
        from(u in Url, where: u.id == ^id and u.user_id == ^user.id)
        |> Repo.update_all(set: [position: position])
      end)
    end)
  end

  defp next_position(user) do
    (Repo.aggregate(assoc(user, :urls), :max, :position) || 0) + 1
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

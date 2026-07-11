defmodule VutuvWeb.UrlController do
  use VutuvWeb, :controller
  alias Vutuv.Profiles.LinkVerification
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
        render(conn, "index.html", as_owner?: false, urls: urls)
      end,
      doc: fn -> SectionDocs.build_index(conn.assigns[:user], :links, urls) end
    )
  end

  # The owner's editor (GET /settings/links): the same list plus the add
  # tile, reorder tool and per-row actions, inside the settings shell.
  def manage(conn, _params) do
    urls = Repo.all(Url.ordered(assoc(conn.assigns[:user], :urls)))
    render(conn, "manage.html", urls: urls, as_owner?: true, page_title: gettext("Links"))
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
        Vutuv.PageScreenshot.generate_async(url)

        conn
        |> put_flash(:info, gettext("Link created successfully."))
        |> redirect(to: ~p"/settings/links")

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
        Vutuv.PageScreenshot.generate_async(url)

        conn
        |> put_flash(:info, gettext("Link updated successfully."))
        |> redirect(to: ~p"/settings/links")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render("edit.html", url: url, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    url = ControllerHelpers.get_owned!(conn, :urls, id)

    ControllerHelpers.delete(conn, url,
      flash: gettext("Link deleted successfully."),
      redirect_to: ~p"/settings/links"
    )
  end

  # The owner-only "prove this link is your webpage" page: mint the token needed
  # for the DNS / well-known instructions, then show the three methods.
  def verify(conn, %{"id" => id}) do
    url =
      conn
      |> ControllerHelpers.get_owned!(:urls, id)
      |> LinkVerification.ensure_token()

    render(conn, "verify.html",
      url: url,
      enabled?: LinkVerification.enabled?(),
      profile_url: LinkVerification.profile_urls(conn.assigns[:user]) |> List.first(),
      host: URI.parse(url.value).host,
      dns_value: LinkVerification.dns_txt_value(url),
      well_known_url: LinkVerification.well_known_url(url),
      well_known_content: LinkVerification.well_known_content(url),
      page_title: gettext("Verify link")
    )
  end

  def run_verify(conn, %{"id" => id} = params) do
    url = ControllerHelpers.get_owned!(conn, :urls, id)
    method = params["method"]
    user = conn.assigns[:user]

    if method in Url.methods() do
      handle_verify(conn, url, user, method)
    else
      redirect(conn, to: ~p"/settings/links/#{url}/verify")
    end
  end

  defp handle_verify(conn, url, user, method) do
    case LinkVerification.verify(url, user, method) do
      {:ok, _url} ->
        conn
        |> put_flash(:info, gettext("Link verified. It now shows a verified mark."))
        |> redirect(to: ~p"/settings/links")

      {:error, :disabled} ->
        conn
        |> put_flash(:error, gettext("Link verification is disabled on this installation."))
        |> redirect(to: ~p"/settings/links/#{url}/verify")

      {:error, :not_found} ->
        conn
        |> put_flash(
          :error,
          gettext(
            "We could not find the proof yet. It can take a while to propagate. Please try again."
          )
        )
        |> redirect(to: ~p"/settings/links/#{url}/verify")
    end
  end
end

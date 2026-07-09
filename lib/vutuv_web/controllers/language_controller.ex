defmodule VutuvWeb.LanguageController do
  use VutuvWeb, :controller

  alias Vutuv.Profiles.Language
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "language" when action in [:create, :update])

  plug(VutuvWeb.Plug.ResolveOwnedSlug,
    parent: :user,
    assoc: :languages,
    slug_param: "id",
    field: :language_code,
    assign: :language
  )

  # Index and show are also served as Markdown / text / JSON / XML via
  # VutuvWeb.AgentDocs.SectionDocs (keep the templates and the doc builder in
  # sync, see agent_docs_drift_test.exs).
  def index(conn, _params) do
    user = Repo.preload(conn.assigns[:user], languages: Language.ordered())

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html", as_owner?: false, user: user, languages: user.languages)
      end,
      doc: fn -> SectionDocs.build_index(user, :languages, user.languages) end
    )
  end

  # The owner's editor (GET /settings/languages).
  def manage(conn, _params) do
    user = Repo.preload(conn.assigns[:user], languages: Language.ordered())

    render(conn, "manage.html",
      user: user,
      languages: user.languages,
      as_owner?: true,
      page_title: gettext("Languages")
    )
  end

  def new(conn, _params) do
    changeset = Language.changeset(%Language{})
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"language" => language_params}) do
    user = conn.assigns[:user]

    changeset =
      user
      # New languages land at the end of the member's chosen order. `position`
      # is set on the struct (not cast) so a forged param can't move it;
      # reordering itself lives in VutuvWeb.SectionReorderLive via Vutuv.Ordering.
      |> build_assoc(:languages, position: Vutuv.Ordering.next_position(Language, user.id))
      |> Language.changeset(language_params)

    ControllerHelpers.save(conn, Repo.insert(changeset),
      flash: gettext("Language added successfully."),
      redirect_to: ~p"/settings/languages",
      render: "new.html"
    )
  end

  def show(conn, _params) do
    # ResolveOwnedSlug scopes :language to conn.assigns[:user], so no re-check.
    AgentDocs.respond(conn,
      html: &render(&1, "show.html", language: conn.assigns[:language]),
      doc: fn ->
        SectionDocs.build_show(conn.assigns[:user], :languages, conn.assigns[:language])
      end
    )
  end

  def edit(conn, _params) do
    language = conn.assigns[:language]
    changeset = Language.changeset(language)
    render(conn, "edit.html", language: language, changeset: changeset)
  end

  def update(conn, %{"language" => language_params}) do
    language = conn.assigns[:language]
    changeset = Language.changeset(language, language_params)

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Language updated successfully."),
      redirect_to: ~p"/settings/languages",
      render: "edit.html",
      assigns: [language: language]
    )
  end

  def delete(conn, _params) do
    ControllerHelpers.delete(conn, conn.assigns[:language],
      flash: gettext("Language deleted successfully."),
      redirect_to: ~p"/settings/languages"
    )
  end
end

defmodule VutuvWeb.MessengerController do
  use VutuvWeb, :controller
  alias Vutuv.Profiles.Messenger
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])

  # Index and show are also served as Markdown / text / JSON / XML via
  # VutuvWeb.AgentDocs.SectionDocs (see agent_docs_drift_test.exs).
  def index(conn, _params) do
    user = user_with_messengers(conn)

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          as_owner?: false,
          user: user,
          messengers: user.messengers,
          page_title: VutuvWeb.UserHelpers.member_page_title(user, gettext("Messengers"))
        )
      end,
      doc: fn -> SectionDocs.build_index(user, :messengers, user.messengers) end
    )
  end

  # The owner's editor (GET /settings/messengers).
  def manage(conn, _params) do
    user = user_with_messengers(conn)

    render(conn, "manage.html",
      user: user,
      messengers: user.messengers,
      as_owner?: true,
      page_title: gettext("Messengers")
    )
  end

  # `from_link` arrives from the links editor's "this belongs under Messengers"
  # suggestion (issue #1442) and carries the id of one of the member's OWN
  # links, never an address: the form is seeded from what `Messenger.from_url/1`
  # reads out of that stored URL, so nothing a visitor typed into the query is
  # reflected back into the form. Seeded on the struct rather than as params, so
  # a prefilled form opens clean instead of pre-scolding.
  def new(conn, params) do
    changeset = Messenger.changeset(seed(conn, params["from_link"]))
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"messenger" => messenger_params}) do
    user = conn.assigns[:user]

    changeset =
      user
      # New entries append to the owner's chosen order (position set on the
      # struct, never cast); reordering lives in VutuvWeb.SectionReorderLive.
      |> build_assoc(:messengers, position: Vutuv.Ordering.next_position(Messenger, user.id))
      |> Messenger.changeset(messenger_params)

    case Repo.insert(changeset) do
      {:ok, _messenger} ->
        conn
        |> put_flash(:info, gettext("Messenger created successfully."))
        |> redirect(to: ~p"/settings/messengers")

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> render("new.html", changeset: changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    messenger = ControllerHelpers.get_owned!(conn, :messengers, id)

    AgentDocs.respond(conn,
      html:
        &render(&1, "show.html",
          messenger: messenger,
          page_title:
            VutuvWeb.UserHelpers.member_page_title(conn.assigns[:user], messenger.provider)
        ),
      doc: fn -> SectionDocs.build_show(conn.assigns[:user], :messengers, messenger) end
    )
  end

  def edit(conn, %{"id" => id}) do
    messenger = ControllerHelpers.get_owned!(conn, :messengers, id)
    changeset = Messenger.changeset(messenger)
    render(conn, "edit.html", messenger: messenger, changeset: changeset)
  end

  def update(conn, %{"id" => id, "messenger" => messenger_params}) do
    messenger = ControllerHelpers.get_owned!(conn, :messengers, id)
    changeset = Messenger.changeset(messenger, messenger_params)

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Messenger updated successfully."),
      redirect_to: ~p"/settings/messengers",
      render: "edit.html",
      assigns: [messenger: messenger]
    )
  end

  def delete(conn, %{"id" => id}) do
    messenger = ControllerHelpers.get_owned!(conn, :messengers, id)

    ControllerHelpers.delete(conn, messenger,
      flash: gettext("Messenger deleted successfully."),
      redirect_to: ~p"/settings/messengers"
    )
  end

  defp seed(conn, id) when is_binary(id) do
    url = ControllerHelpers.get_owned!(conn, :urls, id)

    case Messenger.from_url(url.value) do
      {provider, value} -> %Messenger{provider: provider, value: value}
      nil -> %Messenger{}
    end
  end

  defp seed(_conn, _id), do: %Messenger{}

  defp user_with_messengers(conn),
    do: Repo.preload(conn.assigns[:user], messengers: Messenger.ordered())
end

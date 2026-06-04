defmodule VutuvWeb.GroupController do
  use VutuvWeb, :controller
  alias Vutuv.Social
  alias Vutuv.Social.Group
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser)
  plug(:scrub_params, "group" when action in [:create, :update])

  def index(conn, _params) do
    render(conn, "index.html", groups: Social.list_groups(conn.assigns[:user]))
  end

  def new(conn, _params) do
    changeset = Group.changeset(%Group{})
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"group" => group_params}) do
    ControllerHelpers.save(conn, Social.create_group(conn.assigns[:user], group_params),
      flash: gettext("Group created successfully."),
      redirect_to: ~p"/users/#{conn.assigns[:user]}/groups",
      render: "new.html"
    )
  end

  def show(conn, %{"id" => id}) do
    group = ControllerHelpers.get_owned!(conn, :groups, id)
    render(conn, "show.html", group: group)
  end

  def edit(conn, %{"id" => id}) do
    group = ControllerHelpers.get_owned!(conn, :groups, id)
    changeset = Group.changeset(group)
    render(conn, "edit.html", group: group, changeset: changeset)
  end

  def update(conn, %{"id" => id, "group" => group_params}) do
    group = ControllerHelpers.get_owned!(conn, :groups, id)

    ControllerHelpers.save(conn, Social.update_group(group, group_params),
      flash: gettext("Group updated successfully."),
      redirect_to: &~p"/users/#{conn.assigns[:user]}/groups/#{&1}",
      render: "edit.html",
      assigns: [group: group]
    )
  end

  def delete(conn, %{"id" => id}) do
    group = ControllerHelpers.get_owned!(conn, :groups, id)

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Social.delete_group!(group)

    conn
    |> put_flash(:info, gettext("Group deleted successfully."))
    |> redirect(to: ~p"/users/#{conn.assigns[:user]}/groups")
  end
end

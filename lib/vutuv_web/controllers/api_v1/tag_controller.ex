defmodule VutuvWeb.ApiV1.TagController do
  @moduledoc """
  The authorized user's own tags: `POST /api/v1/me/tags` with
  `{"name": "Phoenix"}` (creates or links the global tag, like the HTML
  form) and `DELETE /api/v1/me/tags/:id` (the user_tag id from the tag
  entries). Reading tags is `GET /api/v1/users/:slug/tags`
  (`VutuvWeb.ApiV1.SectionController`).
  """

  use VutuvWeb, :controller

  alias Vutuv.Tags
  alias Vutuv.UUIDv7
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ApiV1
  alias VutuvWeb.ApiV1.Problem

  plug(VutuvWeb.Plug.RequireScope, "profile:write")

  def create(conn, %{"name" => name}) when is_binary(name) and name != "" do
    user = conn.assigns.current_user

    case Tags.add_user_tag(user, name) do
      {:ok, user_tag} ->
        user_tag = Repo.preload(user_tag, [:tag, :endorsements])
        ApiV1.send_json(conn, SectionDocs.build_show(user, :tags, user_tag), 201)

      {:error, changeset} ->
        Problem.validation_failed(conn, changeset)
    end
  end

  def create(conn, _params) do
    Problem.send_problem(conn, 400, "Bad request",
      detail: ~s(Send a JSON body like {"name": "Phoenix"}.)
    )
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with uuid when is_binary(uuid) <- UUIDv7.cast_or_nil(id),
         %{} = user_tag <- Repo.get(assoc(user, :user_tags), uuid) do
      Repo.delete!(user_tag)
      send_resp(conn, 204, "")
    else
      _missing -> Problem.not_found(conn)
    end
  end
end

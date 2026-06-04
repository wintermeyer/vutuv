defmodule VutuvWeb.Plug.ResolveSlug do
  @moduledoc false

  import Plug.Conn
  import Ecto.Query
  import Phoenix.Controller
  alias Vutuv.Repo

  def init(slug: slug_variable_name, model: model, assign: assign_name, field: field) do
    %{
      slug: slug_variable_name,
      model: model,
      field: field,
      assign: assign_name
    }
  end

  def call(%{params: %{} = params} = conn, %{
        slug: slug_variable_name,
        model: model,
        field: field,
        assign: assign_name
      }) do
    case params do
      %{^slug_variable_name => slug} ->
        case Repo.one(from(m in model, where: field(m, ^field) == ^slug)) do
          nil -> invalid_slug(conn)
          record -> assign(conn, assign_name, record)
        end

      # When the slug param is absent (e.g. a collection action like :index),
      # pass through unchanged so the action can run without the assign.
      _ ->
        conn
    end
  end

  defp invalid_slug(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(html: VutuvWeb.ErrorHTML)
    |> render("404.html")
    |> halt
  end
end

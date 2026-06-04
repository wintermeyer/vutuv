defmodule VutuvWeb.SearchQueryController do
  use VutuvWeb, :controller
  import Vutuv.Search

  alias Vutuv.Search.SearchQuery
  alias Vutuv.Search.SearchQueryRequester

  @email_regex ~r/^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,4}$/

  def index(conn, _params) do
    if conn.assigns[:current_user] do
      queries =
        Repo.all(
          from(q in SearchQuery,
            join: r in assoc(q, :search_query_requesters),
            where: r.user_id == ^conn.assigns[:current_user].id,
            preload: [search_query_requesters: {r, :user}]
          )
        )
        |> Repo.preload(search_query_results: :user)

      render(conn, "index.html", queries: queries)
    else
      redirect(conn, to: ~p"/search_queries/new")
    end
  end

  def new(conn, _params) do
    changeset = SearchQuery.changeset(%SearchQuery{})
    render(conn, "new.html", conn: conn, changeset: changeset)
  end

  def create(conn, %{"search_query" => search_query_params}) do
    # Reject blank queries before running the (expensive) search, so an empty
    # submission re-renders the form with an error instead of erroring out.
    if blank?(search_query_params["value"]) do
      render(conn, "new.html", changeset: blank_value_changeset(search_query_params))
    else
      do_create(conn, search_query_params)
    end
  end

  defp do_create(conn, search_query_params) do
    user = conn.assigns[:current_user]

    search_query_params =
      Map.put(search_query_params, "is_email?", validate_email(search_query_params["value"]))

    results = search(search_query_params["value"], search_query_params["is_email?"])

    Repo.one(from(q in SearchQuery, where: q.value == ^search_query_params["value"]))
    |> insert_or_update(search_query_params, requester_assoc(user), results)
    # insert_or_update returns either a plain Repo result or an Ecto.Multi one
    |> case do
      {:ok, %{search_query: query}} -> query_created(conn, query)
      {:ok, query} -> query_created(conn, query)
      {:error, changeset} -> render(conn, "new.html", changeset: changeset)
      {:error, _failure, changeset, _} -> render(conn, "new.html", changeset: changeset)
    end
  end

  defp query_created(conn, query) do
    conn
    |> put_flash(:info, gettext("Search query executed successfully."))
    |> redirect(to: ~p"/search_queries/#{query}")
  end

  def show(conn, %{"id" => query_id}) do
    empty_changeset = SearchQuery.changeset(%SearchQuery{})
    tags = get_tags(query_id)

    Repo.one(from(q in SearchQuery, where: q.value == ^query_id))
    # if query is nil, it doesn't yet exist, so create it.
    |> case do
      nil ->
        create(conn, %{"search_query" => %{"value" => query_id}})

      query ->
        query = Repo.preload(query, [:search_query_results, :user_results])

        conn
        |> Map.put(
          :params,
          Map.put_new(conn.params, "tags", "#{Enum.count(query.user_results) < Enum.count(tags)}")
        )
        |> render("new.html",
          query: query,
          user_results: query.user_results,
          tag_results: tags,
          changeset: empty_changeset,
          value: query.value,
          work_info_by_id: VutuvWeb.UserHelpers.work_information_map(query.user_results, 45),
          following_by_id:
            VutuvWeb.UserHelpers.following_map(conn.assigns[:current_user], query.user_results)
        )
    end
  end

  defp get_tags(value) do
    Repo.all(
      from(t in Vutuv.Tags.Tag,
        where: like(t.name, ^"#{value}%") or like(t.slug, ^"#{value}%")
      )
    )
  end

  defp validate_email(nil), do: false

  defp validate_email(value) do
    Regex.match?(@email_regex, value)
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  # Build an errored changeset (with a "can't be blank" error on :value) so the
  # form can be re-rendered for a blank query without touching the database.
  defp blank_value_changeset(search_query_params) do
    {:error, changeset} =
      %SearchQuery{}
      |> SearchQuery.changeset(Map.put(search_query_params, "is_email?", false))
      |> Ecto.Changeset.apply_action(:insert)

    changeset
  end

  defp insert_or_update(nil, search_query_params, requester_assoc, results_assocs) do
    # build query changeset from empty struct
    %SearchQuery{}
    |> SearchQuery.changeset(search_query_params)
    |> Ecto.Changeset.put_assoc(:search_query_requesters, [requester_assoc])
    |> Ecto.Changeset.put_assoc(:search_query_results, results_assocs)
    |> Repo.insert()
  end

  defp insert_or_update(query, search_query_params, requester_assoc, results_assocs) do
    # build requester changeset
    requester_changeset =
      requester_assoc
      |> SearchQueryRequester.changeset(%{search_query_id: query.id})

    # build query changeset from existing query
    query_changeset =
      query
      |> Repo.preload([:search_query_results, :search_query_requesters])
      |> SearchQuery.changeset(search_query_params)
      |> Ecto.Changeset.put_assoc(:search_query_results, results_assocs)

    # if one transaction fails, they both fail.
    Ecto.Multi.new()
    |> Ecto.Multi.update(:search_query, query_changeset)
    |> Ecto.Multi.insert(:search_query_requester, requester_changeset)
    |> Repo.transaction()
  end

  # build assoc from existing user unless user is nil
  defp requester_assoc(nil) do
    %SearchQueryRequester{}
    |> SearchQueryRequester.changeset(%{user_id: nil})
  end

  defp requester_assoc(user) do
    Ecto.build_assoc(user, :search_query_requesters)
  end
end

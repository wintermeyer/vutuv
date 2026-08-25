defmodule VutuvWeb.SiteNameTest do
  @moduledoc """
  What this installation calls itself is `:node_name` (`NODE_NAME`), and its
  config comment says an operator "should not have to answer it twice" — but
  sixteen places wrote `"vutuv"` out instead, so a third-party or intranet
  installation shipped link previews, schema.org markup, breadcrumbs and RSS
  channel titles naming somebody else's site.

  `async: false`: `:node_name` is global application env, which the SQL sandbox
  does not roll back, so the whole module holds it for its lifetime.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Posts

  @renamed "Beispiel-Netz"

  setup do
    original = Application.fetch_env(:vutuv, :node_name)
    Application.put_env(:vutuv, :node_name, @renamed)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :node_name, was)
        :error -> Application.delete_env(:vutuv, :node_name)
      end
    end)

    :ok
  end

  test "the landing page's preview card names this installation" do
    html = build_conn() |> get(~p"/") |> html_response(200)

    assert html =~ ~s(content="#{@renamed}")
    refute html =~ ~s(<meta property="og:site_name" content="vutuv")
  end

  test "so does the schema.org markup a search engine reads" do
    user = insert_activated_user()
    {:ok, _post} = Posts.create_post(user, %{body: "Ein Beitrag."})

    html = build_conn() |> get(~p"/#{user.username}") |> html_response(200)

    assert html =~ @renamed
  end

  test "and the RSS channel a reader subscribes to" do
    user = insert_activated_user()
    {:ok, _post} = Posts.create_post(user, %{body: "Ein Beitrag."})

    body = build_conn() |> get(VutuvWeb.Feeds.user_feed_path(user)) |> response(200)

    assert body =~ @renamed
    refute body =~ "on vutuv<"
  end

  # The software's own name is a different question and stays the literal: every
  # installation runs the same software however it names itself.
  test "but the fediverse software name stays vutuv" do
    body = build_conn() |> get(~p"/system/nodeinfo/2.0") |> json_response(200)

    assert body["software"]["name"] == "vutuv"
    assert body["metadata"]["nodeName"] == @renamed
  end
end

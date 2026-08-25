defmodule Vutuv.SourceRepoTest do
  @moduledoc """
  `Vutuv.SourceRepo` owns where this installation's source can be read.

  It had to be given an owner because the URL was written out at thirteen call
  sites in nine files — the footer, both API discovery documents, the media kit,
  the two error pages, the developer docs, the landing page and a flash message
  — two of them frozen as module attributes. A fork pointing at our repository
  is telling its users something untrue about what they are running, and it
  could not correct that claim without editing nine files.

  `async: false`: `put_config/2` flips a global application env, which the SQL
  sandbox does not roll back, so the whole module holds it for its lifetime.
  The only other reader is `Vutuv.SourceRepo` itself.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers, only: [on_mastodon_host: 1]

  alias Vutuv.SourceRepo

  defp put_source(url) do
    original = Application.fetch_env(:vutuv, :source_url)
    Application.put_env(:vutuv, :source_url, url)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :source_url, was)
        :error -> Application.delete_env(:vutuv, :source_url)
      end
    end)
  end

  test "the tracker URLs hang off the configured repository" do
    put_source("https://codeberg.org/fork/vutuv")

    assert SourceRepo.url() == "https://codeberg.org/fork/vutuv"
    assert SourceRepo.issues_url() == "https://codeberg.org/fork/vutuv/issues"
    assert SourceRepo.new_issue_url() == "https://codeberg.org/fork/vutuv/issues/new"
    assert SourceRepo.issues_label() == "codeberg.org/fork/vutuv/issues"
  end

  test "a fork's footer names the fork, not us", %{conn: conn} do
    put_source("https://codeberg.org/fork/vutuv")

    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "https://codeberg.org/fork/vutuv"
    refute html =~ "github.com/wintermeyer/vutuv"
  end

  # `@llms_txt` is a module attribute, so an `#{…}` in that heredoc would freeze
  # the URL at COMPILE time — before `config/runtime.exs` reads `SOURCE_URL`,
  # which is the entire point of the setting. The substitution happens per
  # request instead, and this is what proves it.
  test "the agent discovery file names the configured repository", %{conn: conn} do
    put_source("https://codeberg.org/fork/vutuv")

    body = conn |> get(~p"/llms.txt") |> response(200)

    assert body =~ "https://codeberg.org/fork/vutuv"
    refute body =~ "github.com/wintermeyer/vutuv"
  end

  test "so does the Mastodon instance document", %{conn: conn} do
    put_source("https://codeberg.org/fork/vutuv")

    body = conn |> on_mastodon_host() |> get("/api/v2/instance") |> json_response(200)

    assert body["source_url"] == "https://codeberg.org/fork/vutuv"
  end

  # 2.1 is the version with a place for the source pointers; 2.0 has none.
  test "and the NodeInfo 2.1 document the fediverse directories read", %{conn: conn} do
    put_source("https://codeberg.org/fork/vutuv")

    body = conn |> get(~p"/system/nodeinfo/2.1") |> json_response(200)

    assert body["software"]["repository"] == "https://codeberg.org/fork/vutuv"
  end
end

defmodule Vutuv.MastodonApi.StatusContentTest do
  # A Mastodon client renders a status body the way Mastodon's own web UI does,
  # with the paragraphs preformatted (`white-space: pre-wrap`), so the layout
  # newlines Earmark writes for readability are drawn as blank lines and stray
  # indents. The federated Note and this API are the two wire surfaces that have
  # to answer for it; see `VutuvWeb.Markdown.compact_html/1`.
  use Vutuv.DataCase, async: true

  alias Vutuv.MastodonApi.Presenter

  defp content(body) do
    user = insert(:activated_user)
    post = insert(:post, user: user, body: body)

    post |> Presenter.one_status(user) |> Map.fetch!(:content)
  end

  test "a status carries no layout whitespace" do
    content = content("# Titel\n\nEin Satz.\n\n* eins\n* zwei")

    assert content =~ "<h1>Titel</h1>"
    assert content =~ "<li>eins</li><li>zwei</li>"
    refute content =~ "\n"
  end

  test "a status keeps the newlines inside a code block" do
    assert content("```elixir\ndef a do\n  :ok\nend\n```") =~ "do</span>\n  <span"
  end
end

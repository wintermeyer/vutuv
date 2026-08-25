defmodule VutuvWeb.AgentDocs.PostReplyCountTest do
  @moduledoc """
  The permalink shows the true reply count beside a *window* of the thread —
  `Posts.list_replies/2` stops at `@default_thread_limit` (100).

  `PostDoc` counted its own two loaded lists instead, to keep the number and the
  entries in step. Sound reasoning, wrong arithmetic: past a hundred direct
  replies the page and its `.json` sibling stated different reply counts, which
  is a wrong number rather than a shorter list — and the doc's own comment
  claimed it was "the figure the HTML reply button now shows".

  Calibrated against the un-fixed code, where the JSON says 100 and the page 101.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Posts

  test "past the thread window the doc still states the page's count" do
    author = insert_activated_user()
    {:ok, post} = Posts.create_post(author, %{body: "Womit fangen wir an?"})

    replier = insert_activated_user()

    # One more than the window `list_replies/2` returns.
    for n <- 1..101 do
      {:ok, _} = Posts.create_reply(replier, post, %{body: "Antwort #{n}"})
    end

    shown = Posts.shown_counts(Posts.engagement_counts(post.id))
    assert shown.replies == 101, "the fixture did not build past the window"

    doc = build_conn() |> get(Posts.path(post) <> ".json") |> json_response(200)

    assert doc["reply_count"] == shown.replies,
           "the JSON says #{doc["reply_count"]} replies where the page says #{shown.replies}"

    # And the entries below it stay the window, which is the trade the page makes
    # too — a count is not a promise to list every one of them.
    assert length(doc["replies"]) <= 100
  end
end

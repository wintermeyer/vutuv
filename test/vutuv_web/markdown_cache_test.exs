defmodule VutuvWeb.MarkdownCacheTest do
  @moduledoc """
  `VutuvWeb.Markdown.render_post/3` and `render_remote/1` run the whole
  Markdown pipeline — escaping, autolinking, Earmark, the sanitizer, mentions
  and hashtags — and the same body goes through it again and again: twice per
  feed arrival on its own (the HTML document, then the LiveView's join
  payload), and once more in every other member's feed. `VutuvWeb.Markdown.Cache`
  memoizes the result.

  The cache process is off in the test env (`:markdown_cache`), so every other
  test in the suite renders live — which is also the assertion that a missing
  table changes nothing. These tests start the real-named instance for
  themselves, because the renderers reach for the default table and a body has
  no seam to hand one in through.

  **`async: false`, and it has to be**: what these tests assert is a query
  count, and `:telemetry.attach/4` is global, so an async module would count
  whatever the twenty cases running beside it happened to ask.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Posts.PostImage
  alias VutuvWeb.Markdown
  alias VutuvWeb.Markdown.Cache

  setup do
    start_supervised!(Cache)
    :ok
  end

  # The pipeline asks the database whether a written #hashtag names a topic
  # worth linking, so a body carrying one is what makes the memo visible.
  defp count_queries(fun) do
    ref = make_ref()
    parent = self()
    handler = "mdc-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:vutuv, :repo, :query],
      fn _event, _measure, _meta, _config -> send(parent, {ref, :query}) end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)

    {drain(ref, 0), result}
  end

  defp drain(ref, n) do
    receive do
      {^ref, :query} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  defp html(safe), do: Phoenix.HTML.safe_to_string(safe)

  describe "a member's post body" do
    test "is rendered once and remembered" do
      body = "Ein Satz über #elixir und noch einer."

      {first, rendered} = count_queries(fn -> Markdown.render_post(body, []) end)
      {second, again} = count_queries(fn -> Markdown.render_post(body, []) end)

      assert first > 0, "the first render should have asked the database something"
      assert second == 0, "the second render should have been answered from the memo"
      assert html(rendered) == html(again)
    end

    test "an edited body is a different key, so the edit shows" do
      Markdown.render_post("Vorher.", [])

      assert html(Markdown.render_post("Nachher.", [])) =~ "Nachher."
    end

    test "the same text with different pictures is remembered apart" do
      # Only the whitelisted own attachment may render as an image, so the two
      # image lists produce genuinely different HTML for one body.
      post = insert(:post)
      image = insert(:post_image, post: post)
      body = "![](#{PostImage.url(image, "large")})"

      with_pictures = html(Markdown.render_post(body, [image]))
      without = html(Markdown.render_post(body, []))

      assert with_pictures =~ "<img"
      refute without =~ "<img"
    end

    test "a caller passing an :image_query is never served another caller's URLs" do
      # That option is a function — it has no stable key — so the Mastodon
      # adapter's capability-token URLs must not be cached, nor answer the
      # website's identical body.
      post = insert(:post)
      image = insert(:post_image, post: post)
      body = "![](#{PostImage.url(image, "large")})"

      plain = html(Markdown.render_post(body, [image]))
      tokened = html(Markdown.render_post(body, [image], image_query: fn _ -> "t=secret" end))
      plain_again = html(Markdown.render_post(body, [image]))

      assert tokened =~ "t=secret"
      refute plain =~ "t=secret"
      refute plain_again =~ "t=secret"
    end
  end

  describe "a body from another network" do
    test "is rendered once and remembered" do
      text = "Ein fremder Satz mit #elixir darin."

      {first, rendered} = count_queries(fn -> Markdown.render_remote(text) end)
      {second, again} = count_queries(fn -> Markdown.render_remote(text) end)

      assert first > 0
      assert second == 0
      assert rendered == again
    end
  end

  describe "the memo itself" do
    test "answers a miss when there is no table at all" do
      # What the whole rest of the suite runs under, and the reason a boot that
      # has not finished cannot break a render.
      stop_supervised!(Cache)

      assert :miss = Cache.fetch({:post, "anything"})
      assert "kept" = Cache.put({:post, "x"}, "kept")
      assert html(Markdown.render_post("Immer noch da.", [])) =~ "Immer noch da."
    end

    test "stops answering once an entry has aged out" do
      body = "Ein Satz über #elixir."
      Markdown.render_post(body, [])
      Cache.expire_all()

      {queries, _} = count_queries(fn -> Markdown.render_post(body, []) end)

      assert queries > 0, "an expired entry must fall through to a real render"
    end
  end
end

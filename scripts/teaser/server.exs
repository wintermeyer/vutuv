# Dev server for the teaser recording.
#
#   PORT=4077 mix run --no-start scripts/teaser/server.exs <lang>
#
# The dev database is a copy of production with real fediverse followers and
# push subscriptions, so nothing this server does may reach another machine:
#   * fediverse stays on (the like/repost buttons on remote posts need it), but
#     every outbound ActivityPub request is answered by the local stub below;
#   * web push, screenshot capture and code-stats fetching are off;
#   * Miriam's Mastodon/Bluesky previews are put into the social-feed cache with
#     a year-long TTL, so her fictional accounts are never looked up.
Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
Application.put_env(:vutuv, :fediverse_enabled, true, persistent: true)
Application.put_env(:vutuv, :web_push_enabled, false, persistent: true)
Application.put_env(:vutuv, :generate_screenshots, false, persistent: true)
Application.put_env(:vutuv, :moderate_images, false, persistent: true)

Application.put_env(
  :vutuv,
  :fediverse_req_options,
  [
    retry: false,
    plug: fn conn ->
      IO.puts("FEDI_STUB #{conn.method} #{conn.host}#{conn.request_path}")
      Plug.Conn.send_resp(conn, 202, "")
    end
  ], persistent: true)

{:ok, _} = Application.ensure_all_started(:vutuv)

alias Vutuv.SocialFeed.{Feed, Post}

lang = List.first(System.argv()) || "de"
here = Path.dirname(__ENV__.file)

m =
  here
  |> Path.join("content.#{lang}.json")
  |> File.read!()
  |> Jason.decode!()
  |> Map.fetch!("miriam")

avatar_path = Path.expand("../../_build/teaser/assets/miriam_avatar.jpg", here)

{small, 0} =
  System.cmd("ffmpeg", [
    "-v",
    "error",
    "-i",
    avatar_path,
    "-vf",
    "scale=96:96",
    "-f",
    "image2pipe",
    "-vcodec",
    "mjpeg",
    "-"
  ])

avatar = "data:image/jpeg;base64," <> Base.encode64(small)

at = fn hours ->
  DateTime.utc_now() |> DateTime.add(-hours * 3600) |> DateTime.truncate(:second)
end

posts = fn texts, base, hours ->
  texts
  |> Enum.zip(hours)
  |> Enum.with_index()
  |> Enum.map(fn {{text, h}, i} ->
    %Post{id: "teaser-#{i}", url: "#{base}/#{i + 1}", created_at: at.(h), text: text}
  end)
end

feeds = %{
  {"Mastodon", "miriam@elixir-koblenz.social"} => %Feed{
    name: "Miriam Kessler",
    handle: "@miriam@elixir-koblenz.social",
    url: "https://elixir-koblenz.social/@miriam",
    avatar: avatar,
    followers: 1843,
    posts: posts.(m["mastodon_posts"], "https://elixir-koblenz.social/@miriam", [5, 30, 74])
  },
  {"Bluesky", "miriamkessler.dev"} => %Feed{
    name: "Miriam Kessler",
    handle: "@miriamkessler.dev",
    url: "https://bsky.app/profile/miriamkessler.dev",
    avatar: avatar,
    followers: 956,
    posts: posts.(m["bluesky_posts"], "https://bsky.app/profile/miriamkessler.dev/post", [9, 52])
  }
}

# the cache table is protected, so the insert runs inside the process that owns it
expires = System.monotonic_time(:millisecond) + 365 * 24 * 3600 * 1000

:sys.replace_state(Vutuv.SocialFeed.Cache, fn state ->
  for {key, feed} <- feeds, do: :ets.insert(state.table, {key, {:ok, feed}, expires})
  state
end)

IO.puts("TEASER_SERVER_UP lang=#{lang} fediverse_stubbed=true push=#{Vutuv.WebPush.enabled?()}")
Process.sleep(:infinity)

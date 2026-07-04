defmodule Vutuv.Mastodon do
  @moduledoc """
  The Mastodon client of the inline social feeds (`Vutuv.SocialFeed`): fetches
  a member's latest public Mastodon posts for the profile's "Social media
  posts" card.

  Mastodon is federated and its public API needs no credentials: the stored
  handle `user@instance.tld` (see `Vutuv.Profiles.SocialMediaAccount`) names
  both the account and the server to ask. `fetch_posts/1` resolves the account
  (`/api/v1/accounts/lookup`) and reads its statuses, reduced to sanitized
  plain-text `Vutuv.SocialFeed.Post`s. It never runs in a request or LiveView
  process — `Vutuv.SocialFeed.Cache` owns the fetch tasks (and guarantees an
  account is never fetched twice concurrently); pages talk to
  `Vutuv.SocialFeed` only.

  The remote `content` is HTML from an untrusted federated server. It is
  reduced to plain text here (`text_content/1`) and additionally HEEx-escaped
  at render time — never render any of it with `raw/1`.
  """

  require Logger

  alias Vutuv.SocialFeed.Feed
  alias Vutuv.SocialFeed.Http
  alias Vutuv.SocialFeed.Post

  # How many posts the profile shows, from how many fetched (the API page is
  # larger because replies/boosts are excluded server-side but visibility,
  # sensitive-media and media-only filtering happens here).
  @posts_shown 3
  @statuses_limit 20

  # Same shape the SocialMediaAccount changeset enforces; no ":" keeps port
  # injection out of the URL (https, port 443 only).
  @handle_format ~r/^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$/u

  # The application-env seam tests stub HTTP through (see Vutuv.SocialFeed.Http).
  @req_options :mastodon_req_options

  @doc """
  The blocking fetch (run inside the cache's task, and directly by tests):
  `{:ok, %Feed{}}` or a classified `{:error, :gone | :transient}` — `:gone` is
  a hard error that deactivates the account immediately, `:transient` walks
  the backoff ladder. The avatar is best-effort: any problem with it leaves
  `feed.avatar` nil, never a failed feed.
  """
  def fetch_posts(handle) do
    with {:ok, user, instance} <- split_handle(handle),
         :ok <- guard_instance(instance),
         {:ok, meta} <- lookup_account(instance, user),
         {:ok, posts} <- fetch_statuses(instance, meta.id) do
      {:ok,
       %Feed{
         name: meta.name,
         handle: handle,
         url: meta.url,
         avatar: Http.fetch_avatar(meta.avatar_url, @req_options),
         posts: posts
       }}
    end
  rescue
    error ->
      Logger.warning("mastodon fetch for #{inspect(handle)} raised: #{inspect(error)}")
      {:error, :transient}
  end

  defp split_handle(handle) do
    with true <- is_binary(handle) and Regex.match?(@handle_format, handle),
         [user, instance] <- String.split(handle, "@", parts: 2) do
      {:ok, user, instance}
    else
      _ -> {:error, :gone}
    end
  end

  # The instance host comes from member input; resolve it at fetch time and
  # refuse our own network, like the webhook deliverer (DNS rebinding).
  defp guard_instance(instance) do
    if Vutuv.Ssrf.resolves_to_internal?(instance), do: {:error, :gone}, else: :ok
  end

  defp lookup_account(instance, user) do
    url = "https://#{instance}/api/v1/accounts/lookup?acct=#{URI.encode_www_form(user)}"

    case Http.get(url, @req_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case Http.decode(body) do
          {:ok, %{"id" => id} = account} when is_binary(id) or is_integer(id) ->
            {:ok, account_meta(account, user, instance)}

          _ ->
            {:error, :transient}
        end

      {:ok, %Req.Response{status: status}} when status in [404, 410] ->
        {:error, :gone}

      _other ->
        {:error, :transient}
    end
  end

  # What the feed shows about the account itself, with fallbacks for sparse
  # lookup answers. `avatar_static` is preferred over `avatar` so an animated
  # avatar arrives as its still version.
  defp account_meta(account, user, instance) do
    name =
      Post.presence(strip_custom_emoji(account["display_name"])) ||
        Post.presence(account["username"]) || user

    %{
      id: to_string(account["id"]),
      name: name,
      url: Post.presence(account["url"]) || "https://#{instance}/@#{user}",
      avatar_url: Post.presence(account["avatar_static"]) || Post.presence(account["avatar"])
    }
  end

  # Display names may embed custom-emoji shortcodes (":verified:"); the
  # images they name are per-instance, so here the tokens would render as
  # literal ":verified:" text — drop them. Mastodon delimits shortcodes with
  # non-word boundaries, which is what keeps a plain time ("10:30:45") intact.
  defp strip_custom_emoji(value) when is_binary(value) do
    value
    |> String.replace(~r/(?<=^|\W):\w{2,}:(?=\W|$)/u, "")
    |> String.replace(~r/\s{2,}/, " ")
  end

  defp strip_custom_emoji(value), do: value

  defp fetch_statuses(instance, id) do
    # The id came from the remote server's JSON; only a plain token may be
    # embedded in the path (a crafted id must not redirect the request).
    with true <- Regex.match?(~r/^\w+$/, id),
         {:ok, %Req.Response{status: 200, body: body}} <-
           Http.get(
             "https://#{instance}/api/v1/accounts/#{id}/statuses" <>
               "?limit=#{@statuses_limit}&exclude_replies=true&exclude_reblogs=true",
             @req_options
           ),
         {:ok, statuses} when is_list(statuses) <- Http.decode(body) do
      {:ok, parse_statuses(statuses)}
    else
      _ -> {:error, :transient}
    end
  end

  defp parse_statuses(statuses) do
    statuses
    |> Enum.filter(&(&1["visibility"] in ["public", "unlisted"]))
    |> Enum.flat_map(fn status ->
      case to_post(status) do
        nil -> []
        post -> [post]
      end
    end)
    |> Enum.take(@posts_shown)
  end

  defp to_post(status) do
    text = post_text(status)
    url = status["url"]
    created = status["created_at"]

    with true <- is_binary(url) and url != "" and text != "" and is_binary(created),
         false <- is_nil(status["id"]),
         {:ok, created_at, _offset} <- DateTime.from_iso8601(created) do
      %Post{id: to_string(status["id"]), url: url, text: text, created_at: created_at}
    else
      _ -> nil
    end
  end

  # A content warning replaces the content; sensitive media without one is
  # skipped entirely (empty text drops the status in to_post/1).
  defp post_text(status) do
    spoiler = String.trim(to_string(status["spoiler_text"] || ""))

    cond do
      spoiler != "" -> Post.truncate(spoiler)
      status["sensitive"] == true -> ""
      true -> text_content(to_string(status["content"] || ""))
    end
  end

  @doc """
  Reduces a status' HTML `content` (untrusted, server-rendered by a federated
  instance) to plain text: `<br>`/`</p>` become line breaks, every tag is
  stripped, the base entities are decoded exactly once, and runaway posts are
  capped. The result is plain text that the template interpolates (and HEEx
  escapes again) — the sanitization chokepoint for everything Mastodon.
  """
  def text_content(html) when is_binary(html) do
    html
    |> String.replace(~r{<br\s*/?>}i, "\n")
    |> String.replace(~r{</p>}i, "\n\n")
    |> HtmlSanitizeEx.strip_tags()
    |> decode_entities()
    |> String.trim()
    |> Post.truncate()
  end

  # strip_tags/1 returns text with the base named entities still escaped (the
  # numeric ones it decodes itself); undo them exactly once. `&amp;` must come
  # last so a literal "&amp;amp;" cannot double-unescape.
  defp decode_entities(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
  end
end

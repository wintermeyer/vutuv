defmodule Vutuv.Tags.ExternalTagClient do
  @moduledoc """
  Reads one server's public tag timeline (issue #2126).

  **We pull, nobody pushes.** ActivityPub delivers to addresses, not to topics:
  a hashtag has no inbox to subscribe to, and a remote server's own "follow a
  hashtag" only filters what that server already holds. So a followed tag's
  other servers are asked, over the Mastodon-compatible REST API every one of
  them serves without an account (`GET /api/v1/timelines/tag/:hashtag`), and
  what comes back is reduced to plain text plus a link to the original.

  Three refusals sit in front of the request, and all three are here rather than
  in the changeset that stored the server's name, because all three can change
  after a member picked it:

    * **The operator's instance blocklist.** A member may name a host the
      operator blocks afterwards, so the list is consulted at fetch time, which
      keeps `/admin/fediverse` authoritative whenever the operator edits it. It
      also drops a *status* whose author lives on a blocked host: "drop
      everything that host sends" does not stop being true because a third
      server relayed it.
    * **The SSRF vet, with the connection pinned** (`Http.get_pinned/4`).
      `Vutuv.Tags.TagFollowSource` does the literal check a changeset can afford
      — no DNS — so `metadata.google.internal` is stored, and only a resolve at
      fetch time catches it. Pinned rather than merely checked, or the client's
      own second lookup is the door DNS rebinding walks through.
    * **A tag with no hashtag out there.** A punctuation-only legacy name
      reduces to nothing (`Vutuv.Tags.Tag.hashtag_name/1`), and asking for the
      empty hashtag is asking for a server's whole firehose.

  This is the second reader of the Mastodon REST `Status` entity, so what that
  entity means stays with `Vutuv.Mastodon` (`mention_tags/1`); what is new here
  is the timeline path, the pin, the blocklist and the stricter refusals. The
  remote `content` is HTML from an untrusted server and is reduced to plain text
  through `Vutuv.RemoteHtml` — never render any of it with `raw/1`.

  ## The two other things a server is asked (issue #2129)

  `trending/1` reads `GET /api/v1/trends/tags`, which every Mastodon server
  serves without an account — measured against all ten shipped servers and
  against the three that refuse the *timeline* to a logged-out reader, and all
  thirteen answered it. Each entry carries seven days of `uses`, which is what
  tells a tag that is suddenly busy from one that is busy every day.

  `authors/2` reads the same tag timeline `fetch/2` does, but answers **who
  wrote it** rather than what they wrote: one entry per status, with the
  author's host and the bot flag their own server put on them. Nothing is
  stored from it. It is a separate function rather than a field on `fetch/2`'s
  result because the two callers want opposite things — the pull drops boosts,
  replies and anything sensitive before it counts, and a census that dropped
  them would be counting a different population than the one making the noise.
  """

  require Logger

  alias Vutuv.ChangesetHelpers
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.BlockedInstance
  alias Vutuv.Fediverse.Handle
  alias Vutuv.Mastodon
  alias Vutuv.RemoteHtml
  alias Vutuv.SocialFeed.Http
  alias Vutuv.SocialFeed.Post
  alias Vutuv.Tags.ExternalPost
  alias Vutuv.Tags.Tag

  # The application-env seam tests stub HTTP through — its own key, so a test
  # stubbing this never intercepts the profile card's Mastodon fetches.
  @req_options :external_tag_req_options

  # How many statuses one ask brings back. Deliberately more than the cadence
  # aims to store, so a burst between two fetches is not silently cut short;
  # deliberately far short of a page's maximum (40), because everything past
  # the per-tag cap is thrown away again anyway.
  @statuses_limit 20

  # How many trending tags one server is asked for. Mastodon answers 10 without
  # a `limit` and honours up to 20; the wider list costs the same request and
  # gives the spike and spread gates something to cut down — measured, the ten
  # shipped servers between them named 50 distinct tags at 20 and 20 at 10.
  @trends_limit 20

  # A Mastodon tag's history is a week, and the reader is shown a week.
  @history_days 7

  # How many statuses a trending tag is vetted on. A page's maximum, because
  # this one is a census and its whole value is the size of the sample —
  # measured over ten trending tags, forty statuses gave 10 to 26 distinct
  # author domains for an ordinary one and 2 for the bot wave.
  @census_limit 40

  # A server whose clock runs ahead, or a status dated by hand, must not pin
  # itself to the top of the tag forever: past this much future it is dropped.
  @future_tolerance_seconds 300

  @public ~w(public unlisted)

  # What a stored display identity may take up, read off the schema so the clamp
  # and the column's own guard cannot drift apart.
  @max_display ExternalPost.max_display()
  @max_id ExternalPost.max_id()
  @max_language ExternalPost.max_language()

  @doc """
  The newest usable statuses `source` carries for `tag_name`, as maps ready for
  `Vutuv.Tags.ExternalPost`.

    * `{:ok, posts}` — possibly empty, which is an ordinary answer.
    * `{:error, :blocked | :internal}` — the pair cannot be fetched at all, and
      nothing about the remote side failed, so the caller skips it without a
      strike.
    * `{:error, :gone}` — this server will not serve this timeline (see
      `refusal/1`), so the tag has no address there.
    * `{:error, :transient | :unresolvable}` — a bad day at the other end, DNS
      included. A strike.
  """
  def fetch(source, tag_name) do
    with {:ok, hashtag} <- hashtag(tag_name),
         :ok <- refuse_blocked(source),
         {:ok, statuses} <- get_timeline(source, hashtag) do
      {:ok, parse(statuses, source)}
    end
  rescue
    error ->
      Logger.warning(
        "external tag fetch #{source}/#{inspect(tag_name)} raised: #{inspect(error)}"
      )

      {:error, :transient}
  end

  @doc """
  What `source` says is trending right now: `{:ok, [%{name:, history:}]}` with
  `history` the seven daily use counts, newest first.

  The same three refusals as `fetch/2`, minus the hashtag one — this asks about
  no tag in particular. A server that answers something which is not a list of
  tags is a `:transient` failure rather than a crash: these are strangers'
  documents and half of what could come back is not JSON at all.
  """
  def trending(source) do
    with :ok <- refuse_blocked(source),
         {:ok, entries} <- get_json(source, "/api/v1/trends/tags?limit=#{@trends_limit}") do
      {:ok, entries |> List.wrap() |> Enum.flat_map(&trend/1)}
    end
  rescue
    error ->
      Logger.warning("external tag trends #{source} raised: #{inspect(error)}")
      {:error, :transient}
  end

  # The Mastodon `Tag` entity. `uses` and `accounts` arrive as **strings**, and
  # a `history` shorter than a week is padded rather than refused: a tag first
  # seen three days ago has three entries, and reading that as "no history" is
  # the same mistake as reading it as a spike.
  defp trend(%{"name" => name, "history" => history}) when is_binary(name) and is_list(history) do
    case Tag.hashtag_name(name) do
      nil -> []
      cleaned -> [%{name: cleaned, history: week(history)}]
    end
  end

  defp trend(_entry), do: []

  # `uses` arrives as a string here and as a number in NodeInfo, and both are a
  # stranger's counter going into a `bigint` column — so both go through
  # `Post.whole_number/2`. A day that cannot be read is a day nothing happened,
  # which is 0; that fallback is the only thing this reader and the panel's
  # disagree about.
  defp week(history) do
    counts =
      Enum.map(history, fn
        %{"uses" => uses} -> Post.whole_number(uses, 0)
        _other -> 0
      end)

    Enum.take(counts ++ List.duplicate(0, @history_days), @history_days)
  end

  @doc """
  Who is posting `tag_name` on `source`: `{:ok, [%{host:, bot?:}]}`, one entry
  per status on its public tag timeline.

  The two facts a trending tag is vetted on, and both are the *server's* own —
  it flags its bot accounts itself, and `acct` says where the author lives. See
  the moduledoc for why this is not a by-product of `fetch/2`.
  """
  def authors(source, tag_name) do
    with {:ok, hashtag} <- hashtag(tag_name),
         :ok <- refuse_blocked(source),
         {:ok, statuses} <- get_timeline(source, hashtag, @census_limit) do
      {:ok, Enum.flat_map(statuses, &author_entry(&1, source))}
    end
  rescue
    error ->
      Logger.warning("external tag authors #{source} raised: #{inspect(error)}")
      {:error, :transient}
  end

  defp author_entry(status, source) do
    case {author_host(status, source), status["account"]} do
      {host, %{} = account} when is_binary(host) -> [%{host: host, bot?: account["bot"] == true}]
      _unusable -> []
    end
  end

  defp get_json(source, path) do
    case Http.get_pinned(source, path, @req_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case Http.decode(body) do
          {:ok, decoded} when is_list(decoded) -> {:ok, decoded}
          _other -> {:error, :transient}
        end

      {:ok, %Req.Response{status: status}} ->
        if refusal(status), do: {:error, :gone}, else: {:error, :transient}

      {:error, reason} when reason in [:internal, :unresolvable] ->
        {:error, reason}

      _other ->
        {:error, :transient}
    end
  end

  defp hashtag(tag_name) do
    case Tag.hashtag_name(tag_name) do
      nil -> {:error, :gone}
      name -> {:ok, name}
    end
  end

  defp refuse_blocked(source) do
    if Fediverse.instance_blocked?(source), do: {:error, :blocked}, else: :ok
  end

  defp get_timeline(source, hashtag, limit \\ @statuses_limit) do
    get_json(
      source,
      "/api/v1/timelines/tag/#{URI.encode(hashtag, &URI.char_unreserved?/1)}?limit=#{limit}"
    )
  end

  @doc """
  What a status code from a public tag timeline means, for the two readers of
  one: `:account_required`, `:absent`, or `nil` for "not a refusal".

  **`422` is Mastodon's own way of saying "this method requires an
  authenticated user"** — not the 401 the shape suggests. Measured while
  shipping #2128: three of eighteen servers answer exactly that, and read as a
  bad day it is a strike on every pass, backing a refusal that will never
  change off to the three-hour ceiling.

  One classifier because the next lesson (a 429, a 451) must not have to be
  learned twice — and because the panel needs the *reason* while the fetcher
  needs only that it is permanent.
  """
  def refusal(status) when status in [401, 403, 422], do: :account_required
  def refusal(status) when status in [404, 410], do: :absent
  def refusal(_status), do: nil

  @doc """
  Whether an error from here is **nobody's fault and possibly temporary from
  outside**: the operator's blocklist, an internal address, a server that will
  not serve this at all.

  Both sweepers reading this client answer such an outcome with a skip — no
  strike, and the longest wait before anybody looks again. It lives here rather
  than in either of them because this module is what produces the atoms, so the
  next lesson (a 429, a 451) is learned in one place instead of two lists that
  nothing connects.
  """
  def skip?(reason), do: reason in [:blocked, :internal, :gone]

  defp parse(statuses, source) do
    now = DateTime.utc_now(:second)
    with_hosts = Enum.map(statuses, &{&1, author_host(&1, source)})

    # One query for the whole timeline: a busy tag carries close to twenty
    # distinct author hosts, and asking per status would be twenty round trips
    # against a table holding tens of rows.
    blocked =
      with_hosts
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)
      |> Fediverse.blocked_hosts()

    Enum.flat_map(with_hosts, fn {status, host} ->
      case to_post(status, source, host, now, blocked) do
        nil -> []
        post -> [post]
      end
    end)
  end

  # A timeline carries other servers' posts too, so the author's host is a
  # second host to ask the blocklist about.
  defp author_host(status, source) do
    case status["account"] do
      %{"acct" => acct} when is_binary(acct) ->
        case String.split(acct, "@", parts: 2) do
          [_user, host] -> BlockedInstance.normalize_host(host)
          _local -> source
        end

      _ ->
        nil
    end
  end

  defp to_post(status, source, host, now, blocked) do
    # `host` is nil when the status names no author we can parse. That is the
    # degraded path, and it fails **closed**: `MapSet.member?(blocked, nil)` is
    # simply false, so without this guard an unparseable author would walk past
    # the operator's blocklist rather than be refused by it.
    #
    # `written_here?/1` is the second refusal that reads a host rather than the
    # server we asked (issue #2179): our own posts travel out with their
    # hashtags, so the servers a followed tag names carry them and hand them
    # back as finds. It sits after `permalink/1` because it asks about the
    # address as well as the author, and a status with no address is refused on
    # the next line anyway.
    with true <- is_binary(host),
         true <- showable?(status),
         false <- MapSet.member?(blocked, host),
         text when text != "" <- text_of(status),
         url when is_binary(url) <- permalink(status),
         false <- ExternalPost.written_here?(host, url),
         id when is_binary(id) <- remote_id(status),
         language when is_nil(language) or is_binary(language) <- language(status),
         {:ok, published_at} <- published_at(status, now) do
      %{
        source: source,
        remote_id: id,
        url: url,
        text: text,
        language: language,
        published_at: published_at,
        # Whose server this is, as opposed to the one we asked. Computed here
        # anyway to ask the blocklist about it, and stored since #2127 because
        # that is what the card names and what every later reader compares
        # against the blocklist and the reader's own muted servers.
        author_host: host
      }
      |> Map.merge(author(status))
    else
      _refused -> nil
    end
  end

  # A boost is somebody else's post travelling under this account's name: the
  # original carries the hashtag itself and arrives on its own. A reply is half
  # a conversation nobody here can see the other half of. Anything not public
  # has no business being copied here at all — a tag timeline should carry none,
  # and "should" is not a gate.
  defp showable?(status) do
    is_nil(status["reblog"]) and is_nil(status["in_reply_to_id"]) and
      status["visibility"] in @public and status["sensitive"] != true and
      Post.presence(status["spoiler_text"]) == nil
  end

  defp text_of(status) do
    status["content"]
    |> to_string()
    |> RemoteHtml.to_text(nil, Mastodon.mention_tags(status))
  end

  defp permalink(status) do
    if ChangesetHelpers.web_url?(status["url"]), do: status["url"]
  end

  # An id is a token, not prose: one longer than the column holds is not a
  # status we can file, so it goes rather than being cut to a value that names
  # something else. Measured in bytes, the unit the column's own guard uses.
  defp remote_id(%{"id" => id}) when is_binary(id), do: bounded(id, @max_id)
  defp remote_id(%{"id" => id}) when is_integer(id), do: Integer.to_string(id)
  defp remote_id(_status), do: nil

  # Same for the declared language: a value this long is not a language code,
  # and guessing at one would be worse than storing none.
  defp language(status) do
    case Post.presence(status["language"]) do
      nil -> nil
      value -> bounded(value, @max_language)
    end
  end

  defp bounded(value, max) when byte_size(value) <= max, do: value
  defp bounded(_value, _max), do: nil

  defp published_at(status, now) do
    with created when is_binary(created) <- status["created_at"],
         {:ok, at, _offset} <- DateTime.from_iso8601(created),
         at = DateTime.truncate(at, :second),
         true <- DateTime.diff(at, now) <= @future_tolerance_seconds do
      {:ok, at}
    else
      _unusable -> :error
    end
  end

  # A display identity is somebody's chosen spelling of themselves, so it is
  # **clamped, never refused**: dropping a stranger's post because their name is
  # long would be the wrong answer, and `Handle.display_name/1` normalises
  # whitespace and shortcodes but does not bound anything — an ordinary ZWJ
  # emoji name is a handful of graphemes and hundreds of codepoints.
  defp author(status) do
    case status["account"] do
      %{} = account ->
        %{
          author_name:
            account["display_name"] |> Handle.display_name() |> Post.clamp_bytes(@max_display),
          author_acct: account["acct"] |> Post.presence() |> Post.clamp_bytes(@max_display),
          author_url: if(ChangesetHelpers.web_url?(account["url"]), do: account["url"])
        }

      _ ->
        %{}
    end
  end
end

defmodule VutuvWeb.PostTeaser do
  @moduledoc """
  What an arrival says in one line: who wrote it, how it opens, and whether this
  reader may be shown it at all.

  Two surfaces quote a post the reader is not looking at, and neither may drift
  from the other. The feed's source-tab ticker quotes it beside the tab it
  landed on (issue #1668); the browser tab's title teases it while the whole
  window sits behind something else (issue #1681). Both ask the same three
  questions, so all three answers live here instead of twice.

  `title_frames/1` is the browser tab's half and belongs here for the same
  reason: it cuts the quote the two surfaces share, and where it cuts is a
  decision about how a tab strip reads, not about the feed.
  """

  alias Vutuv.ContentFilters
  alias Vutuv.Fediverse.Handle
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Identity
  alias Vutuv.Posts
  alias VutuvWeb.Markdown

  # How wide one browser-tab frame is written. A tab in a window holding a
  # handful of others shows roughly twenty characters of its title, and the
  # marker the hook keeps in front ("• (2) ") spends some of those, so a frame
  # is cut a little above what is certainly visible: the tail of a frame is
  # truncated, and the words after it arrive in the next one anyway.
  @frame_width 24

  # How many frames a teaser may run to. Not a taste decision — browsers clamp
  # timers in a hidden tab to about one per second, and Chrome drops a chained
  # timer to one per *minute* once the page has been hidden for five minutes
  # ("intensive throttling", Chrome 88), which is exactly the tab this feature
  # is for. Measured in headless Chrome 151, a frame asking for a second gets
  # two, so three frames plus the closing one take about eight seconds of the
  # window the browser is willing to give. Whatever stands last has to still be
  # true a minute later.
  @max_frames 3

  @doc """
  The quote for one feed entry — `%{who: …, text: …}` — or nil where this
  reader has muted it.

  nil rather than a redacted line: the member silenced that word, and a teaser
  is the one place they cannot scroll past it. Both surfaces then fall back to
  the bare dot, which says *that* something landed without saying what.
  """
  def quote_for(entry, compiled, viewer_id) do
    if filtered_pattern(entry, compiled, viewer_id) do
      nil
    else
      %{who: who(entry), text: text(entry)}
    end
  end

  @doc """
  Which of this reader's content filters hides `entry`, or nil.

  A cached post from another network (issue #1161) is filtered on its plain
  text: the member muted a word because they do not want to read it, and where
  it was written changes nothing about that. Never the member's own posts — a
  remote post cannot reach that arm, having no author here.
  """
  def filtered_pattern(entry, compiled, viewer_id) do
    cond do
      Posts.remote_feed_entry?(entry) ->
        ContentFilters.filtered_text(remote_text(entry), compiled)

      entry.post.user_id == viewer_id ->
        nil

      true ->
        ContentFilters.filtered_pattern(entry.post, compiled)
    end
  end

  @doc """
  Who wrote it, as a name a reader recognises — or nil.

  The handle without its server (`Handle.short/1`): the surfaces quoting this
  are short of room, and the domain would take half of it. A page that never
  claimed a root handle has none to show, so it is named instead.
  """
  def who(entry) do
    cond do
      Posts.remote_reply_entry?(entry) ->
        Handle.short(Handle.display(entry.note.handle, entry.note.actor_uri))

      Posts.remote_feed_entry?(entry) ->
        Handle.short(RemoteAccount.display_handle(entry.remote_post.remote_account))

      true ->
        case Posts.author(entry.post) do
          nil -> nil
          author -> local_who(author)
        end
    end
  end

  @doc """
  How it opens: one line, whatever the body did — or nil for a post with no
  text to quote (a photo without a caption).
  """
  def text(entry) do
    cond do
      Posts.remote_reply_entry?(entry) -> one_line(entry.note.content_text)
      Posts.remote_feed_entry?(entry) -> one_line(entry.remote_post.content_text)
      true -> one_line(Markdown.to_preview_line(entry.post.body))
    end
  end

  @doc """
  The quote cut into browser-tab-sized frames, at word boundaries, newest words
  last. `[]` where there is nothing to say.

  Paging beats scrolling here. Under a budget of about four frames a character
  scroll spends most of them re-showing words it already showed, while paging
  puts a fresh line in the tab each second — roughly seventy characters of the
  post against sixteen. The author leads the first frame and is not repeated:
  a reader who glances late gets the words, and the tab is the member's own, so
  the question "who is this from" is the smaller one.
  """
  def title_frames(nil), do: []

  def title_frames(%{who: who, text: text}) do
    case join(who, text) do
      "" -> []
      line -> line |> chunks(@frame_width) |> Enum.take(@max_frames)
    end
  end

  defp local_who(author) do
    case Identity.handle(author) do
      handle when is_binary(handle) -> "@" <> handle
      _ -> Identity.display_name(author)
    end
  end

  defp remote_text(entry) do
    if Posts.remote_reply_entry?(entry),
      do: entry.note.content_text,
      else: entry.remote_post.content_text
  end

  # A quote is one line whatever the body did. The cap keeps a long post out of
  # the payload; where the line is actually cut is the surface's own business.
  defp one_line(text) when is_binary(text) do
    case text |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 200) do
      "" -> nil
      line -> line
    end
  end

  defp one_line(_text), do: nil

  defp join(who, text) when is_binary(who) and is_binary(text), do: who <> ": " <> text
  defp join(who, nil) when is_binary(who), do: who
  defp join(nil, text) when is_binary(text), do: text
  defp join(_who, _text), do: ""

  # Greedy word wrap. A word wider than a frame gets a frame of its own, cut
  # hard — a pasted URL must not swallow the two frames after it as well.
  defp chunks(line, width) do
    line
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.flat_map(&split_long(&1, width))
    |> wrap(width, [], [])
  end

  defp split_long(word, width) do
    if String.length(word) <= width do
      [word]
    else
      word
      |> String.graphemes()
      |> Enum.chunk_every(width)
      |> Enum.map(&Enum.join/1)
    end
  end

  defp wrap([], _width, [], done), do: Enum.reverse(done)
  defp wrap([], _width, current, done), do: Enum.reverse([finish(current) | done])

  defp wrap([word | rest], width, current, done) do
    cond do
      current == [] ->
        wrap(rest, width, [word], done)

      String.length(finish([word | current])) <= width ->
        wrap(rest, width, [word | current], done)

      true ->
        wrap([word | rest], width, [], [finish(current) | done])
    end
  end

  defp finish(current), do: current |> Enum.reverse() |> Enum.join(" ")
end

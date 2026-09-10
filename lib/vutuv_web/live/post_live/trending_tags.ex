defmodule VutuvWeb.PostLive.TrendingTags do
  @moduledoc """
  "Suddenly very busy on other servers" — the row of tags under the feed's tag
  card that offers what is spiking elsewhere, one press to follow (issue #2129).

  What is on offer, and why any of it is there, is `Vutuv.Tags.Trending`'s
  business; this draws it.

  ## Why every pill carries a week

  A number on its own cannot say "suddenly". `#xbox` at 130 uses a day is a
  busy tag and not news; `#warntag` at 1,084 against three the day before is.
  So each pill wears the seven days the judgement was made on — six quiet
  strokes and today in the accent colour — which is the shortest way to show a
  reader the thing they would otherwise have to take on trust. The bars are
  decorative (`aria-hidden`); the same fact is in the control's own name, in
  words and in grouped figures.

  ## One press, and it is a follow like any other

  The pill is the whole control. Pressing it mints the tag here if nothing
  answers to it yet and names the servers it is busy on as its sources, so the
  follow brings something back rather than subscribing the reader to a topic
  nobody here has written about. Everything after that is the ordinary tag
  follow: the chip appears in the row above with its own server count, and the
  panel from #2128 edits it.

  The card lives in the feed's rail, which is `hidden md:block`, so this is a
  desktop surface for now — the same gap the tag chip beside it has.
  """

  use VutuvWeb, :html

  alias Vutuv.Tags.TrendingTag

  # How tall the shortest stroke is, as a share of the row. A day with no uses
  # at all still gets one: a gap where a bar should be reads as a rendering
  # fault rather than as a quiet Tuesday.
  @min_bar 8

  @doc "The offered tags, or nothing at all when there are none."
  attr(:tags, :list, required: true)

  def trending_row(assigns) do
    ~H"""
    <div :if={@tags != []} id="trending-tags" class="pt-2">
      <p class="pb-1 text-xs text-slate-500 dark:text-slate-400">
        {gettext("Very busy on other servers right now:")}
      </p>
      <div class="flex flex-wrap gap-2">
        <.trending_pill :for={tag <- @tags} tag={tag} />
      </div>
    </div>
    """
  end

  attr(:tag, :map, required: true)

  # The label is derived once here rather than twice in the markup, where the
  # `title` and the accessible name would each cost their own gettext call.
  defp trending_pill(assigns) do
    assigns =
      assigns
      |> assign(:label, pill_label(assigns.tag))
      |> assign(:bars, bars(assigns.tag))

    ~H"""
    <button
      id={"trending-tag-#{@tag.id}"}
      type="button"
      phx-click="follow-trending-tag"
      phx-value-name={@tag.name}
      title={@label}
      aria-label={@label}
      class="flex min-h-10 max-w-full items-center gap-2 rounded-lg bg-slate-100 px-3 py-1.5 text-sm font-semibold text-slate-700 transition hover:bg-slate-200 hover:text-slate-900 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700 dark:hover:text-slate-100"
    >
      <span class="min-w-0 truncate">{@tag.name}</span>
      <span aria-hidden="true" class="flex h-4 flex-shrink-0 items-end gap-px">
        <span
          :for={height <- @bars.previous}
          class="w-1 rounded-sm bg-slate-300 dark:bg-slate-600"
          style={"height:#{height}%"}
        >
        </span>
        <span class="w-1 rounded-sm bg-accent" style={"height:#{@bars.today}%"}></span>
      </span>
    </button>
    """
  end

  # `%{count}` is bound to the raw integer by `ngettext/3` and a `count:`
  # binding does not override it, so every figure here rides its own
  # placeholder — and every one of them is grouped for the reader's locale,
  # because a run-together `1084` is a bug.
  defp pill_label(tag) do
    ngettext(
      "Follow %{tag}. %{uses} uses today on %{servers} server, against %{baseline} on an ordinary day.",
      "Follow %{tag}. %{uses} uses today on %{servers} servers, against %{baseline} on an ordinary day.",
      tag.servers,
      tag: tag.name,
      uses: delimited_count(tag.uses),
      servers: delimited_count(tag.servers),
      baseline: delimited_count(tag.baseline)
    )
  end

  # Oldest day on the left, today on the right — the direction a week is read
  # in — each bar scaled against the busiest day of the seven so the shape says
  # how far out of the ordinary today is.
  defp bars(tag) do
    peak = tag.history |> Enum.max(fn -> 0 end) |> max(1)

    %{
      previous: tag |> TrendingTag.previous() |> Enum.reverse() |> Enum.map(&height(&1, peak)),
      today: height(tag.uses, peak)
    }
  end

  defp height(value, peak), do: max(round(value * 100 / peak), @min_bar)
end

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

  **The week is sized to the pill, never the other way round** (issue #2180).
  This is the third row of pills in one card and the two above it are the
  reader's yardstick, so it wears their recipe to the utility — `text-xs`,
  `px-2.5 py-1`, `font-medium` — and the sparkline fits inside it: `h-4` is
  exactly that type's line box, so the whole pill is 24px tall like its
  neighbours, and the strokes are hairlines (`w-0.5`, 20px for the week against
  34px before). Drawn to its own bigger recipe with a 40px box it cost five
  lines of a 309px rail where two do, and each tag landed on a line of its own
  while the row above sat three to a line — which reads as a fault rather than
  as emphasis. Keep the two literals in step; `feed_trending_tags_test.exs`
  measures them against each other rather than against a number typed here.

  ## The row keeps its place when there is nothing on it

  A tag qualifies on today's volume against its own six-day median, so shortly
  after midnight nothing anywhere can clear the bar and the offer is empty for
  a few hours, every night (issue #2165). Taking the label away with it left a
  member who saw five suggestions in the evening looking at a bare plus sign,
  with nothing saying the row exists — a nightly occurrence that reads as
  breakage. So the label stands and one muted line says what and why.

  What must **not** draw that line is an installation nobody is asked on:
  `asking?` carries `Vutuv.Tags.Trending.asking?/0`, and an intranet vutuv with
  no source servers gets no row at all rather than a nightly report about
  servers it never reads.

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

  @doc """
  The offered tags, and the row's own empty state.

  `asking?` is `Vutuv.Tags.Trending.asking?/0`, and it is the row's whole gate:
  an empty list means two opposite things, and only one of them is worth a line
  of the card — see the moduledoc.
  """
  attr(:tags, :list, required: true)
  attr(:asking?, :boolean, required: true)

  def trending_row(assigns) do
    ~H"""
    <div :if={@asking?} id="trending-tags" class="pt-2">
      <p class="pb-1 text-xs text-slate-500 dark:text-slate-400">
        {gettext("Very busy on other servers right now:")}
      </p>
      <%!-- One condition, two arms: the empty line and the pills are exclusive,
      and a pair of sibling `:if`s leaves that to a convention two lines apart. --%>
      <%= if @tags == [] do %>
        <p class="text-xs text-slate-500 dark:text-slate-400">
          {gettext(
            "Nothing yet today. A topic has to run well ahead of its own last week, which takes a few hours."
          )}
        </p>
      <% else %>
        <div class="flex flex-wrap gap-2">
          <.trending_pill :for={tag <- @tags} tag={tag} />
        </div>
      <% end %>
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
      class="flex max-w-full items-center gap-1.5 rounded-lg bg-slate-100 px-2.5 py-1 text-xs font-medium text-slate-600 hover:bg-slate-200 hover:text-slate-900 dark:bg-slate-800 dark:text-slate-300 dark:hover:bg-slate-700 dark:hover:text-slate-100"
    >
      <span class="min-w-0 truncate">{@tag.name}</span>
      <span aria-hidden="true" class="flex h-4 flex-shrink-0 items-end gap-px">
        <span
          :for={height <- @bars.previous}
          class="w-0.5 bg-slate-300 dark:bg-slate-600"
          style={"height:#{height}%"}
        >
        </span>
        <span class="w-0.5 bg-accent" style={"height:#{@bars.today}%"}></span>
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

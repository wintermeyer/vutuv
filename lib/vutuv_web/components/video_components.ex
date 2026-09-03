defmodule VutuvWeb.VideoComponents do
  @moduledoc """
  Everything a page draws for a post's clip (issue #1906): the player on the
  card, the tile the composer and the waiting card share, the waiting card
  itself, and the words for where the pipeline is.

  One module, so the four surfaces that show the same clip cannot describe
  it in four vocabularies.
  """

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.UI,
    only: [
      hourglass: 1,
      card: 1,
      button: 1,
      picture: 1,
      picture_badge_class: 0,
      quality_switch: 1
    ]

  alias Phoenix.LiveView.JS
  alias Vutuv.Posts.PostVideo
  alias Vutuv.Videos

  ## The player (issue #1912)

  @doc """
  The clip on a post card: the cover with a play glyph and the length, and
  on a tap the native player — no autoplay, nothing preloaded, so a clip
  nobody plays costs the page its poster and not a byte more. The sources are
  `Vutuv.Posts.PostVideo.sources/2`, best first; the browser takes the first
  it can decode.

  For a viewer in data-saving mode the 360p files come first and
  `VutuvWeb.UI.quality_switch/1` sits in the top corner (issue #1924): a tap
  reloads the player with the full files where it was, the way the same switch
  swaps a full picture in (`app.js`, `[data-video-hd]`).
  """
  attr(:video, PostVideo, required: true)
  attr(:class, :any, default: nil)

  def post_video(assigns) do
    video = assigns.video
    picture = PostVideo.cover_picture(video)
    lite? = PostVideo.lite?(video)

    # `assign/3`, not `Map.put/3`: these follow the clip, and a clip changes
    # under the card (an enhancement lands, the cover moves), so they have to
    # be tracked as changed with it or the `<source>` list goes stale.
    assigns =
      assigns
      |> assign(:sources, PostVideo.sources(video, lite?: lite?))
      |> assign(:hd_sources, if(lite?, do: Jason.encode!(PostVideo.sources(video, lite?: false))))
      |> assign(:poster, picture.lite || picture.src)
      |> assign(:lite?, lite?)
      |> assign(:aspect, aspect_style(video))
      |> assign(:label, video_label(video))

    ~H"""
    <figure
      :if={@sources != []}
      class={["mt-3", @class]}
      data-post-video={@video.id}
      data-video-figure
      data-hd-sources={@hd_sources}
    >
      <div
        class="relative overflow-hidden rounded-xl bg-slate-950 ring-1 ring-slate-200 dark:ring-slate-800"
        style={@aspect}
      >
        <video
          controls
          preload="none"
          playsinline
          poster={@poster}
          width={@video.width}
          height={@video.height}
          aria-label={@label}
          data-video-player
          class="block h-full w-full"
        >
          <source :for={source <- @sources} src={source.src} type={source.type} />
        </video>
        <%!-- The play glyph and the length sit on the poster until the first
        play; the native controls take over from there (`[data-playing]`,
        components.css). Pointer events pass through to the player. --%>
        <span
          data-video-overlay
          aria-hidden="true"
          class="pointer-events-none absolute inset-0 flex items-center justify-center"
        >
          <span class="flex h-16 w-16 items-center justify-center rounded-full bg-slate-900/70 text-white shadow-lg">
            <.play_icon class="ml-1 h-8 w-8" />
          </span>
        </span>
        <%!-- Top-left, not bottom-left like the tiles: Chrome and Safari draw
        the native control bar along the bottom of the poster before the
        first play, and a chip under it was half hidden (measured on the
        phone-width smoke test). --%>
        <span
          data-video-overlay
          aria-hidden="true"
          class={["pointer-events-none absolute left-2 top-2 tabular-nums", picture_badge_class()]}
        >
          {duration_label(@video)}
        </span>
        <%!-- Top corner, like the length chip and for the same reason: the
        browser draws its own control bar along the bottom of the poster
        before the first play. --%>
        <.quality_switch
          :if={@lite?}
          corner={:top}
          data-video-hd=""
          label={gettext("Standard quality. Play this video in HD.")}
        />
      </div>
      <figcaption :if={@video.alt != ""} class="sr-only">{@video.alt}</figcaption>
    </figure>
    """
  end

  defp video_label(%PostVideo{alt: alt}) when is_binary(alt) and alt != "", do: alt
  defp video_label(_video), do: gettext("Video")

  defp aspect_style(video), do: "aspect-ratio: #{video.width || 16} / #{video.height || 9};"

  ## The tile (composer and waiting card)

  @doc """
  The clip as the author sees it while it is being worked on: the cover once
  the frames exist, an hourglass tile before that, the length, and the stage
  line — all fed by the `{:post_video, …}` summary every listener receives.
  """
  attr(:video, PostVideo, required: true)
  attr(:class, :any, default: nil)
  slot(:inner_block)

  def video_tile(assigns) do
    assigns =
      assigns
      |> assign(:cover, cover_picture(assigns.video))
      |> assign(:aspect, aspect_style(assigns.video))

    ~H"""
    <div class={["relative overflow-hidden rounded-lg ring-1 ring-slate-200 dark:ring-slate-800", @class]} style={@aspect} data-video-tile={@video.stage}>
      <.picture
        :if={@cover}
        picture={@cover}
        alt=""
        wrap_class="h-full w-full"
        class="block h-full w-full object-cover"
      />
      <div
        :if={!@cover}
        class="flex h-full w-full flex-col items-center justify-center gap-2 bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400"
      >
        <.hourglass class="h-7 w-7" />
      </div>
      <span
        aria-hidden="true"
        class={["pointer-events-none absolute bottom-2 left-2 tabular-nums", picture_badge_class()]}
      >
        {duration_label(@video)}
      </span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # The poster while the author looks at their own clip: the cover once
  # written (author-only until the post exists — the proxy asks), else nothing.
  defp cover_picture(%PostVideo{cover_written_at: nil}), do: nil
  defp cover_picture(%PostVideo{stage: stage}) when stage in ~w(rejected failed), do: nil
  defp cover_picture(video), do: PostVideo.cover_picture(video)

  @doc """
  The stage as a sentence: where the pipeline is with this clip, in the
  author's terms. The percent is the H.264 file's, the count the check's.
  """
  attr(:video, PostVideo, required: true)
  attr(:class, :any, default: "text-xs text-slate-600 dark:text-slate-400")

  def stage_line(assigns) do
    ~H"""
    <p class={@class} data-video-stage={@video.stage} role="status" aria-live="polite">
      {stage_text(@video)}
    </p>
    """
  end

  @doc "The stage as plain text — the chip and the tests read this."
  def stage_text(%PostVideo{stage: "queued"}), do: gettext("Waiting in line")
  def stage_text(%PostVideo{stage: "frames"}), do: gettext("Reading the frames")

  def stage_text(%PostVideo{stage: "transcoding", progress: progress}),
    do: gettext("Converting · %{percent} %", percent: progress)

  def stage_text(%PostVideo{stage: "checking"} = video) do
    %{total: total, checked: checked} = Videos.check_progress(video)

    ngettext(
      "Our AI is checking it.",
      "Our AI is checking it, %{done} of %{total} frames done.",
      total,
      done: checked,
      total: total
    )
  end

  def stage_text(%PostVideo{stage: "ready"}), do: gettext("Ready")

  def stage_text(%PostVideo{stage: "rejected", rejected_second: second}) when is_integer(second),
    do: gettext("Our AI check refused this video (at %{time}).", time: clock(second))

  def stage_text(%PostVideo{stage: "rejected"}), do: gettext("Our AI check refused this video.")
  def stage_text(%PostVideo{stage: "failed"}), do: gettext("This video could not be converted.")
  def stage_text(%PostVideo{}), do: ""

  ## The waiting card (issues #1910, #1911)

  @doc """
  The author's own post while it waits for its clip, in their feed: the
  text, the tile with the stage, the length rounded up to whole minutes, and
  a way out — cancel while it works, publish without the video or drop it
  once the clip was refused. The host handles the three events.
  """
  attr(:pending, Vutuv.Posts.PendingVideoPost, required: true)
  attr(:body_html, :any, required: true, doc: "the rendered text")

  def pending_video_post(assigns) do
    video = assigns.pending.video

    assigns =
      assigns
      |> assign(:video, video)
      |> assign(:refused?, video == nil or PostVideo.refused?(video))

    ~H"""
    <.card class="mt-3" data-pending-video-post={@pending.id} data-pending-status={(@refused? && "refused") || "working"}>
      <p class="flex items-center gap-2 text-sm font-semibold text-slate-900 dark:text-slate-100">
        <.hourglass :if={!@refused?} class="h-4 w-4 text-amber-600 dark:text-amber-400" />
        {if @refused?,
          do: gettext("This post is still waiting for you"),
          else: gettext("Your post appears as soon as the video is ready")}
      </p>
      <div :if={@body_html} class="markdown markdown--post mt-2 text-slate-800 dark:text-slate-200">
        {@body_html}
      </div>
      <div :if={@video} class="mt-3 sm:flex sm:items-start sm:gap-4">
        <.video_tile video={@video} class="w-full sm:w-64 sm:shrink-0" />
        <div class="mt-2 min-w-0 sm:mt-0">
          <.stage_line video={@video} class="text-sm text-slate-700 dark:text-slate-200" />
          <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
            {gettext("About %{minutes} min of video", minutes: minutes_up(@video))}
          </p>
        </div>
      </div>
      <p :if={!@video} class="mt-2 text-sm text-red-700 dark:text-red-300">
        {gettext("The video is gone.")}
      </p>
      <div class="mt-3 flex flex-wrap gap-2">
        <.button
          :if={@refused?}
          type="button"
          phx-click="publish-without-video"
          phx-value-id={@pending.id}
          data-publish-without-video
        >
          {gettext("Post without the video")}
        </.button>
        <.button
          type="button"
          variant="danger-ghost"
          phx-click={JS.push("cancel-pending-video", value: %{id: @pending.id})}
          data-cancel-pending-video
        >
          {if @refused?, do: gettext("Delete this post"), else: gettext("Cancel")}
        </.button>
      </div>
    </.card>
    """
  end

  ## Words and numbers

  @doc "The clip's length as `m:ss` — the chip on the poster."
  def duration_label(%PostVideo{} = video), do: clock(PostVideo.seconds(video))

  @doc "Seconds as `m:ss` — the one spelling of a moment in a clip."
  def clock(seconds) when is_integer(seconds) do
    "#{div(seconds, 60)}:#{String.pad_leading("#{rem(seconds, 60)}", 2, "0")}"
  end

  @doc "The length in whole minutes, rounded up — never `0`, a clip is at least a minute of waiting."
  def minutes_up(%PostVideo{} = video), do: max(1, div(PostVideo.seconds(video) + 59, 60))

  attr(:class, :string, default: "h-5 w-5")

  defp play_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" class={@class} aria-hidden="true">
      <path d="M8 5.14v13.72a1 1 0 0 0 1.5.86l11-6.86a1 1 0 0 0 0-1.72l-11-6.86A1 1 0 0 0 8 5.14z" />
    </svg>
    """
  end
end

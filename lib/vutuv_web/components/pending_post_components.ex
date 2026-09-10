defmodule VutuvWeb.PendingPostComponents do
  @moduledoc """
  What the author sees while their post waits for its media (issue #2106).

  Four surfaces show the same wait — the composer's file chips, the waiting
  card above the feed, the chip in the app bar and the author's own page at
  `/system/uploads` — and they all draw from the one author topic
  (`Vutuv.Posts.Pending.topic/1`). So the words for a stage live here, once:
  four vocabularies for one pipeline is exactly how an author ends up unable
  to tell whether anything is happening at all.

  The clip's own tile and stage sentence stay in `VutuvWeb.VideoComponents` —
  they are about a clip, not about waiting.
  """

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.UI, only: [hourglass: 1, card: 1, button: 1, file_size: 1, delimited_count: 1]
  import VutuvWeb.VideoComponents, only: [video_tile: 1, stage_line: 1, minutes_up: 1]

  alias Phoenix.LiveView.JS
  alias Vutuv.Posts.Pending
  alias Vutuv.Posts.PendingPost
  alias Vutuv.Posts.PostVideo

  ## The stage, as a sentence

  @doc """
  Where the server is with this post, in the author's terms — the one place
  that turns `Vutuv.Posts.Pending.stage/1` into words.

  Every number in it is formatted and every phrase is one translatable string
  with placeholders: `ngettext/3` binds `%{count}` to the raw integer and a
  `count:` binding does not override it, so a formatted figure needs a
  placeholder of its own.
  """
  def stage_text({:video, %PostVideo{} = video}),
    do: VutuvWeb.VideoComponents.stage_text(video)

  def stage_text({:rendering, done, total}) do
    gettext("Rendering page %{page} of %{total}",
      page: delimited_count(min(done + 1, total)),
      total: delimited_count(total)
    )
  end

  def stage_text({:checking, count}) do
    ngettext(
      "Our AI is checking %{formatted} picture.",
      "Our AI is checking %{formatted} pictures.",
      count,
      formatted: delimited_count(count)
    )
  end

  def stage_text(:refused), do: gettext("Something in this post was refused.")
  def stage_text(:ready), do: gettext("Publishing it now")

  @doc "The stage as a live region, for a surface that shows one post."
  attr(:stage, :any, required: true, doc: "`Vutuv.Posts.Pending.reading/1`'s stage")
  attr(:class, :any, default: "text-sm text-slate-700 dark:text-slate-200")

  def pending_stage_line(assigns) do
    ~H"""
    <p class={@class} data-pending-stage={stage_key(@stage)} role="status" aria-live="polite">
      {stage_text(@stage)}
    </p>
    """
  end

  defp stage_key({:video, _video}), do: "video"
  defp stage_key({:rendering, _done, _total}), do: "rendering"
  defp stage_key({:checking, _count}), do: "checking"
  defp stage_key(other), do: to_string(other)

  ## The files

  @doc """
  One line per file this post is waiting on: what it is called, how big it is,
  and whether it is still being worked on, done, or refused.
  """
  attr(:attachments, :list, required: true)
  attr(:states, :map, required: true, doc: "`Vutuv.Posts.Pending.reading/1`'s file_states")
  attr(:class, :any, default: nil)

  def pending_files(assigns) do
    ~H"""
    <ul class={["space-y-1", @class]} data-pending-files={length(@attachments)}>
      <li
        :for={attachment <- @attachments}
        class="flex flex-wrap items-center gap-2 text-sm text-slate-700 dark:text-slate-200"
        data-pending-file={attachment.id}
        data-file-state={@states[attachment.id]}
      >
        <span class="min-w-0 truncate">📎 {attachment.file_name}</span>
        <span class="shrink-0 text-xs text-slate-500 dark:text-slate-400">
          {file_size(attachment.size_bytes)}
        </span>
        <span class={["shrink-0 text-xs", file_tone(@states[attachment.id])]}>
          {file_label(@states[attachment.id])}
        </span>
      </li>
    </ul>
    """
  end

  @doc """
  The word for a file's state (`Vutuv.Posts.Pending.file_state/1`), and its
  colour. Only the wording lives here — a second reading of the columns would
  be a second answer, and a chip saying "ready" beside a post that then parks
  is the exact confusion this issue is about.
  """
  def file_label(:refused), do: gettext("refused")
  def file_label(:working), do: gettext("being prepared")
  def file_label(:done), do: gettext("ready")

  @doc "The colour that word takes."
  def file_tone(:refused), do: "text-red-700 dark:text-red-300"
  def file_tone(:working), do: "text-amber-700 dark:text-amber-300"
  def file_tone(:done), do: "text-slate-500 dark:text-slate-400"

  # Its own msgid per subject, never one shared phrase: a post waiting on a
  # clip and a post waiting on files are two different sentences, and the
  # German for the clip one says "Video".
  defp waiting_headline(true, _files), do: gettext("This post is still waiting for you")
  defp waiting_headline(false, []), do: gettext("Your post appears as soon as the video is ready")

  defp waiting_headline(false, _files),
    do: gettext("Your post appears as soon as its files are ready")

  ## The waiting card

  @doc """
  The author's own post while it waits, in their feed: the text, the clip's
  tile when there is one, a line per file, the stage, and a way out — cancel
  while it works, publish without what was refused or drop it once something
  was. The host handles the two events.
  """
  attr(:pending, PendingPost, required: true)
  attr(:body_html, :any, required: true, doc: "the rendered text")

  attr(:reading, :map,
    default: nil,
    doc: "`Vutuv.Posts.Pending.reading/1`; a page of cards reads them all at once"
  )

  def pending_post(assigns) do
    reading = assigns.reading || Pending.reading(assigns.pending)

    assigns =
      assigns
      |> assign(:video, assigns.pending.video)
      |> assign(:files, reading.files)
      |> assign(:file_states, reading.file_states)
      |> assign(:stage, reading.stage)
      |> assign(:refused?, reading.state == :refused)
      |> assign(:leftover?, reading.publishable_without_refused?)

    ~H"""
    <.card
      class="mt-3"
      data-pending-post={@pending.id}
      data-pending-status={(@refused? && "refused") || "working"}
    >
      <p class="flex items-center gap-2 text-sm font-semibold text-slate-900 dark:text-slate-100">
        <.hourglass :if={!@refused?} class="h-4 w-4 text-amber-600 dark:text-amber-400" />
        {waiting_headline(@refused?, @files)}
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
      <.pending_files
        :if={@files != []}
        attachments={@files}
        states={@file_states}
        class="mt-3"
      />
      <%!-- Unconditional: `Pending.stage/1` already decides which medium is
      worth naming (the clip first, and only while it is still working), so a
      gate here would silence the files the moment a clip turned ready. --%>
      <.pending_stage_line
        stage={@stage}
        class="mt-2 text-sm text-slate-700 dark:text-slate-200"
      />
      <div class="mt-3 flex flex-wrap gap-2">
        <.button
          :if={@refused? and @leftover?}
          type="button"
          phx-click="publish-without-refused"
          phx-value-id={@pending.id}
          data-publish-without-refused
        >
          {gettext("Post without it")}
        </.button>
        <.button
          type="button"
          variant="danger-ghost"
          phx-click={JS.push("cancel-pending-post", value: %{id: @pending.id})}
          data-cancel-pending-post
        >
          {if @refused?, do: gettext("Delete this post"), else: gettext("Cancel")}
        </.button>
      </div>
    </.card>
    """
  end
end

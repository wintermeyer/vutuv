defmodule VutuvWeb.Teaser do
  @moduledoc """
  The teaser film (`scripts/teaser/`): where its files live, which cut a reader
  gets, and the player's sources. Shared by the start page, which opens it in a
  dialog, and by the investor page and the media kit, which both close on
  `card/1` (the player plus the addresses to copy): one component, so a change
  reaches both pages.

  Two languages, German for German readers and English for everybody else,
  and three cuts: 16:9 at 960×540 and at 1920×1080, and 9:16 at 720×1280 for a
  phone, each as AV1 with an H.264 fallback, plus the 16:9 poster.
  `:landing_teaser_video` switches it off everywhere.
  """
  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.UI, only: [copy_field: 1, duration: 1, file_size: 1]

  alias VutuvWeb.AgentDocs
  alias VutuvWeb.Teaser.Mp4
  alias VutuvWeb.UI

  @dir "/images/teaser"

  # The files handed out to pass on, as {language, format, suffix}.
  @downloads for lang <- ~w(de en),
                 {format, suffix} <- [{"16:9", ".hd.mp4"}, {"9:16", "-portrait.mp4"}],
                 do: {lang, format, suffix}

  # Running time and size of each, read at compile time from the committed
  # files: a reader decides on a download by them, and a figure typed in by
  # hand would go stale the next time `scripts/teaser/` renders the film.
  @static Path.expand("../../../priv/static", __DIR__)

  @meta (for {lang, _format, suffix} <- @downloads, into: %{} do
           file = Path.join(@static, "#{@dir}/vutuv-teaser-#{lang}#{suffix}")
           @external_resource file

           # The renders are faststart, so `mvhd` sits in the first bytes.
           head = File.open!(file, [:read, :binary], &IO.binread(&1, 4096))
           duration_ms = Mp4.duration_ms(head) || raise "no mvhd duration in #{file}"
           {{lang, suffix}, %{bytes: File.stat!(file).size, duration_ms: duration_ms}}
         end)

  # Below `md`: where the 9:16 cut plays, and on the start page plays full
  # screen.
  @phone "(max-width: 767px)"

  @doc "Whether this installation shows the teaser at all."
  def enabled?, do: Application.get_env(:vutuv, :landing_teaser_video, true)

  @doc "The media query a phone matches, for the portrait sources and full screen."
  def phone, do: @phone

  @doc "The cut for the current reader: German for German readers, English for everybody else."
  def lang, do: if(Gettext.get_locale(VutuvWeb.Gettext) == "de", do: "de", else: "en")

  @doc "One file of one language's teaser, by its suffix."
  def path(lang, suffix), do: "#{@dir}/vutuv-teaser-#{lang}#{suffix}"

  @doc "The poster: the 16:9 one, on a phone too."
  def poster(lang), do: path(lang, ".avif")

  @doc """
  The addresses to pass on, absolute: each language as 16:9 in full HD and as
  9:16, the H.264 files, which play wherever a link ends up. The language is
  named in itself, so a reader finds theirs whatever the page is in. The label
  adds running time and file size, formatted for the current locale.
  """
  def downloads do
    for {lang, format, suffix} <- @downloads do
      %{bytes: bytes, duration_ms: duration_ms} = Map.fetch!(@meta, {lang, suffix})

      # Rounded up to whole seconds, like every post video's label
      # (`Vutuv.Posts.PostVideo.seconds/1`); `duration/1` would truncate.
      running_time = duration(div(duration_ms + 999, 1_000) * 1_000)

      %{
        language: lang,
        format: format,
        label: "#{language_name(lang)} · #{format} · #{running_time} · #{file_size(bytes)}",
        bytes: bytes,
        duration_ms: duration_ms,
        url: AgentDocs.abs_url(path(lang, suffix))
      }
    end
  end

  defp language_name("de"), do: "Deutsch"
  defp language_name("en"), do: "English"

  @doc """
  Everything the teaser card says, for `card/1` and for the agent formats of
  both pages: heading, sentence, the cut to play and the addresses (none where
  the installation switched the teaser off).

  `locale` pins the language for a page that does not follow the reader's (the
  media kit is English in every locale); `nil` takes the reader's.
  """
  def texts(nil) do
    %{
      film_title: gettext("Teaser"),
      film_note:
        gettext(
          "A short teaser that quickly shows the main features, without sound. The addresses below are MP4 files that play anywhere, 16:9 in full HD for a screen and 9:16 for a phone."
        ),
      pass_on: gettext("To pass on"),
      lang: lang(),
      videos: if(enabled?(), do: downloads(), else: [])
    }
  end

  def texts(locale), do: Gettext.with_locale(VutuvWeb.Gettext, locale, fn -> texts(nil) end)

  @doc """
  The teaser card: heading, sentence, the player in the reader's cut, and the
  addresses to copy. Closes the investor page and the media kit.

  The texts are read before `~H`, because a template's dynamic parts render
  after this function returns, outside any locale pinned around the call.
  """
  attr(:id, :string, required: true)
  attr(:locale, :string, default: nil, doc: "a fixed locale, or nil for the reader's")

  def card(assigns) do
    assigns = assign(assigns, texts(assigns.locale))

    ~H"""
    <UI.card id={@id}>
      <h2 class="text-xl font-bold text-slate-900 dark:text-white">{@film_title}</h2>
      <p class="mt-3 max-w-2xl text-slate-700 dark:text-slate-300">{@film_note}</p>
      <video
        preload="none"
        controls
        playsinline
        poster={poster(@lang)}
        class="mt-4 block aspect-[9/16] w-full rounded-xl bg-slate-900 object-contain md:aspect-video"
      >
        <.sources lang={@lang} />
      </video>
      <h3 class="mt-6 font-semibold text-slate-900 dark:text-white">{@pass_on}</h3>
      <ul class="mt-2 grid gap-3 md:grid-cols-2">
        <li :for={video <- @videos}>
          <p class="text-sm font-semibold text-slate-700 dark:text-slate-300">{video.label}</p>
          <.copy_field
            id={"#{@id}-url-#{video.language}-#{String.replace(video.format, ":", "-")}"}
            copy_text={video.url}
            wrap="anywhere"
            class="mt-1"
          >
            {video.url}
          </.copy_field>
        </li>
      </ul>
    </UI.card>
    """
  end

  @doc """
  A teaser `<video>`'s sources, in the order a browser should weigh them: a
  phone finds the 9:16 cut first, everybody else the 16:9 one, and each comes
  as AV1 first, H.264 second (a browser takes the first source whose `media`
  matches and whose type it plays; Safari claims AV1 only where the hardware
  decodes it). The 16:9 ones carry their full-resolution twin in
  `data-hd-src` for a quality choice beside the player (`app.js`).
  """
  attr(:lang, :string, required: true)

  def sources(assigns) do
    assigns = assign(assigns, :phone, @phone)

    ~H"""
    <source
      src={path(@lang, "-portrait.av1.mp4")}
      type="video/mp4; codecs=av01.0.05M.08"
      media={@phone}
    />
    <source src={path(@lang, "-portrait.mp4")} type="video/mp4" media={@phone} />
    <source
      src={path(@lang, ".av1.mp4")}
      type="video/mp4; codecs=av01.0.04M.08"
      data-hd-src={path(@lang, ".hd.av1.mp4")}
      data-hd-type="video/mp4; codecs=av01.0.08M.08"
    />
    <source src={path(@lang, ".mp4")} type="video/mp4" data-hd-src={path(@lang, ".hd.mp4")} />
    """
  end
end

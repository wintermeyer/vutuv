defmodule VutuvWeb.Teaser do
  @moduledoc """
  The teaser film (`scripts/teaser/`): where its files live, which cut a reader
  gets, and the player's sources. Shared by the start page, which opens it in a
  dialog, and the investor page, which plays it in a card and hands out its
  addresses to copy.

  Two languages, German for German readers and English for everybody else,
  and three cuts: 16:9 at 960×540 and at 1920×1080, and 9:16 at 720×1280 for a
  phone, each as AV1 with an H.264 fallback, plus the 16:9 poster.
  `:landing_teaser_video` switches it off everywhere.
  """
  use Phoenix.Component

  alias VutuvWeb.AgentDocs

  @dir "/images/teaser"

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
  named in itself, so a reader finds theirs whatever the page is in.
  """
  def downloads do
    for lang <- ~w(de en), {format, suffix} <- [{"16:9", ".hd.mp4"}, {"9:16", "-portrait.mp4"}] do
      %{
        language: lang,
        format: format,
        label: "#{language_name(lang)} · #{format}",
        url: AgentDocs.abs_url(path(lang, suffix))
      }
    end
  end

  defp language_name("de"), do: "Deutsch"
  defp language_name("en"), do: "English"

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

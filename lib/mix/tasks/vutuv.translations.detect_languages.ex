defmodule Mix.Tasks.Vutuv.Translations.DetectLanguages do
  @moduledoc """
  Names the language of every post, remote post and remote reply that declares
  none (issue #1535), newest first, until the pile is drained.

  The one-off backfill of everything written before the language column
  existed: milestone 13 filled the column from the composer select and from AS2
  `contentMap` only, so the reader's language filter never applied to older
  rows and the Translate action offered itself on posts in the reader's own
  language. The regular inflow (remote objects arriving without a
  `contentMap`) is handled by `Vutuv.Translations.Worker`'s own small batch.

      mix vutuv.translations.detect_languages
      mix vutuv.translations.detect_languages --max-rows 200
      mix vutuv.translations.detect_languages --force   # ignores :translate_posts

  Needs Ollama reachable; it stops early and says so if Ollama goes quiet, and
  a second run picks up where it left off. On a release use
  `bin/vutuv eval "Vutuv.Release.detect_post_languages()"`.
  """

  use Mix.Task

  alias Vutuv.Translations

  @shortdoc "Detects the language of posts that declare none"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _errors} =
      OptionParser.parse(args, strict: [max_rows: :integer, force: :boolean])

    Mix.Task.run("app.start")

    result =
      Translations.detect_all(
        Keyword.put(opts, :progress, fn checked -> Mix.shell().info("#{checked} checked …") end)
      )

    summary = Translations.detect_summary(result)

    case result do
      {:paused, _checked} -> Mix.shell().error(summary)
      _finished -> Mix.shell().info(summary)
    end

    result
  end
end

defmodule Vutuv.Translations.Detector do
  @moduledoc """
  Names the language of a post nobody declared one for (issue #1535).

  Milestone 13 shipped no detection on purpose — the author declares, and the
  columns filled from the composer select and from AS2 `contentMap`. What that
  left is a pile of rows from before the column existed, plus every remote
  object whose origin sends no `contentMap`: undeclared, so the reader's
  language filter never applies to them and the Translate action offers itself
  on posts in the reader's own language. This module answers the one question
  that pile needs, and `Vutuv.Translations.detect_due/1` walks it.

  It is a **cheap** call next to `Vutuv.Translations.Translator`: a short
  sample instead of the whole body, one field instead of a translation, a
  handful of tokens. Deliberately the translator's own model **and its context
  size** (`Translator.model/0`, `Translator.num_ctx/0`) — Ollama keys its
  resident runner on the model plus its options, so a second model *or a
  smaller window* would have it swapping tens of gigabytes in and out between a
  detection and a translation, which costs far more than either call.

  Two error classes, the translator's:

    * `{:error, {:service, reason}}` — Ollama unreachable. Nothing is known
      about the text, so the sweep stamps nothing and stops; the row is due
      again on the next round.
    * `{:error, {:content, reason}}` — there was nothing to go on
      (`:no_sample`) or the model could not place it (`:undetermined`). The
      sweep stamps the row and leaves `language` NULL, which is the honest
      answer: shown to everyone, never auto-translated.

  What may be stored is `Translations.cast_language/1`'s answer, the same rule
  the composer and the AS2 ingest write through: a curated language or nothing.
  """

  alias Jason.OrderedObject
  alias Vutuv.MarkdownContent
  alias Vutuv.Ollama
  alias Vutuv.Translations
  alias Vutuv.Translations.Translator

  @req_options_key :translation_req_options

  # Language shows in the first couple of sentences; a longer sample buys
  # nothing and costs prefill on a box the image moderation shares.
  @sample_length 600

  # Below this there is nothing to recognise — a photo post, a bare link, an
  # emoji. Saying so without a model call is both cheaper and more honest.
  @min_sample_length 20

  @doc """
  The language of `subject`'s text as a lowercase primary subtag, or a
  two-class error (see the moduledoc). Never returns `"und"`: a model that
  cannot tell is an `:undetermined` content error, so the caller stamps the
  row rather than storing a language nobody can filter by.
  """
  def detect(subject) do
    sample = subject |> Translations.source_text() |> sample()

    if String.length(sample) < @min_sample_length do
      {:error, {:content, :no_sample}}
    else
      ask(sample)
    end
  end

  defp ask(sample) do
    body = %{
      model: Translator.model(),
      stream: false,
      format: schema(),
      options: %{temperature: 0, num_ctx: Translator.num_ctx()},
      messages: [%{role: "user", content: prompt(sample)}]
    }

    # `remote_timeout:` because a priority-list `:ollama_url` skips its first
    # instance after 30 s, which a cold model load alone can exceed. The plain
    # `timeout:` is left at `Ollama.post/3`'s own default — a one-word answer
    # has no use for the translator's patient ten minutes.
    case Ollama.post("/api/chat", body,
           remote_timeout: Ollama.default_timeout(),
           req_options_key: @req_options_key
         ) do
      {:ok, response} -> parse(response)
      {:error, _reason} = error -> error
    end
  end

  defp prompt(sample) do
    """
    Name the language this text is written in.

    Answer with a JSON object holding one property, "language": the BCP47
    primary language subtag ("de", "en", "fr", …). If the text is too short,
    is not language at all, or mixes languages with no clear main one, answer
    "und".

    The text:

    #{sample}
    """
  end

  defp schema do
    OrderedObject.new(
      type: "object",
      required: ["language"],
      properties: OrderedObject.new(language: %{type: "string"})
    )
  end

  defp parse(%{"message" => %{"content" => content}}) when is_binary(content) do
    with {:ok, %{"language" => answer}} <- Jason.decode(content),
         language when is_binary(language) <- Translations.cast_language(answer) do
      {:ok, language}
    else
      _undetermined -> {:error, {:content, :undetermined}}
    end
  end

  defp parse(_body), do: {:error, {:content, :undetermined}}

  # What is left of the text once the parts that carry no language are gone:
  # code (fenced and inline, through the one owner of that rule), URLs,
  # @handles and #tags. A post that is one link plus a German sentence must not
  # be read as English because the link path happens to be English words.
  defp sample(text) do
    text
    |> MarkdownContent.strip_code()
    |> String.replace(~r{https?://\S+}, " ")
    |> String.replace(~r/[@#][\w.@-]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @sample_length)
  end
end

defmodule Vutuv.Translations.Translator do
  @moduledoc """
  The Ollama client behind on-demand post translations (issue #1457): **one**
  call per (subject, target language) that translates the text and reports
  the source language as a byproduct — there is no separate detection step
  anywhere, the author's declaration (issue #1489) and this report are the
  only sources of language truth.

  Local posts are Markdown and the prompt says so: code fences, URLs,
  `@handles` and `#tags` stay untouched, and the result renders through the
  normal `VutuvWeb.Markdown` pipeline + sanitizer, so a translation opens no
  new XSS surface. Remote content (`Vutuv.Fediverse.RemotePost` /
  `Vutuv.Fediverse.Note`) is already plain text (`Vutuv.RemoteHtml`): its
  `content_text` and `summary` (content warning) translate as plain text.

  Errors are two-class, and the worker treats them differently:

    * `{:error, {:service, reason}}` — Ollama unreachable, HTTP failure. The
      text is fine; the service is not. Retried patiently.
    * `{:error, {:content, reason}}` — the model's answer failed the
      plausibility checks (empty, absurd length ratio, altered code fence).
      Counts toward the strike cap; at the cap the job ends `failed` and the
      card keeps showing the original — junk is never stored.

  The model comes from `:ollama_translation_model` (deliberately separate
  from the vision model — issue #1455 picked gemma4:31b). `num_ctx` is set
  explicitly: Ollama truncates silently otherwise, and the eval measured the
  20,000-char body cap comfortably inside 16k tokens. Tests inject a `plug:`
  responder via the `:translation_req_options` config key (the Req seam every
  outbound client here uses), answering with a real
  `content-type: application/json`.
  """

  alias Jason.OrderedObject
  alias Vutuv.Posts.Post
  alias Vutuv.Translations

  @req_options_key :translation_req_options

  # Prompt + a 20k-char body + the translated answer all fit well inside 16k
  # tokens (the #1455 eval's 11k-char worst case used ~6.4k in total). Set
  # explicitly — Ollama silently truncates at its default otherwise.
  @num_ctx 16_384

  # The answer must be a translation, not a summary and not an essay. Beyond
  # these bounds the model lost the thread; strike instead of storing junk.
  @min_length_ratio 0.3
  @max_length_ratio 3.0

  @markdown_rules """
  The post is Markdown. Preserve the Markdown structure exactly: headings,
  lists, blockquotes, links, emphasis. Leave code fences (``` blocks), URLs,
  @handles and #tags completely untouched. Keep emoji where they are.
  """

  @plain_rules """
  The post is plain text. Do not add any formatting or Markdown. Leave URLs,
  @handles and #tags completely untouched. Keep emoji where they are.
  """

  @doc """
  Translates `subject` (a `Vutuv.Posts.Post`, `Vutuv.Fediverse.RemotePost` or
  `Vutuv.Fediverse.Note`) into `target_language`. Returns
  `{:ok, %{source_language: …, body: …, summary: …, model: …}}` ready for
  `Vutuv.Translations.store_translation/3`, or a two-class error (moduledoc).
  """
  def translate(subject, target_language) do
    text = Translations.source_text(subject)
    summary = Translations.source_summary(subject)

    body = %{
      model: model(),
      stream: false,
      format: schema(summary),
      options: %{temperature: 0, num_ctx: @num_ctx},
      messages: [%{role: "user", content: prompt(subject, text, summary, target_language)}]
    }

    case Vutuv.Ollama.post("/api/chat", body,
           timeout: timeout(),
           req_options_key: @req_options_key
         ) do
      {:ok, response} -> parse(response, text, summary)
      {:error, _reason} = error -> error
    end
  end

  defp prompt(subject, text, summary, target_language) do
    """
    You are a professional translator. Translate the following social-media
    post into the language with BCP47 tag "#{target_language}".

    Rules:
    #{format_rules(subject)}\
    - Translate idiomatically, never word for word, but never change the
      meaning. Negations must stay negations.
    - Keep the paragraph structure: same number of paragraphs.

    Answer with a JSON object:
    - "source_language": the BCP47 tag of the language the post is written in
      ("de", "en", or another tag if it is neither)
    - "body": the full translation
    #{summary_instruction(summary)}
    The post:

    #{text}
    """
  end

  defp format_rules(%Post{}), do: @markdown_rules
  defp format_rules(_remote), do: @plain_rules

  defp summary_instruction(nil), do: ""

  defp summary_instruction(summary) do
    """
    - "summary": the translation of this content warning: #{Jason.encode!(summary)}
    """
  end

  # Ollama structured output: the model may only answer this shape, and the
  # property order is generation order (OrderedObject, not a map) — the
  # source language is a one-token answer, so it comes first and cannot be
  # biased by the translation that follows.
  defp schema(summary) do
    base = [
      source_language: %{type: "string"},
      body: %{type: "string"}
    ]

    props = if summary, do: base ++ [summary: %{type: "string"}], else: base

    OrderedObject.new(
      type: "object",
      required: Enum.map(props, fn {key, _} -> Atom.to_string(key) end),
      properties: OrderedObject.new(props)
    )
  end

  # The answer arrives as a JSON string in the assistant message (the schema
  # constrains generation, but never trust it enough to skip validation).
  defp parse(%{"message" => %{"content" => content}}, text, summary) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"body" => body} = answer} when is_binary(body) ->
        vet(answer, body, text, summary)

      _ ->
        {:error, {:content, :bad_answer}}
    end
  end

  defp parse(_body, _text, _summary), do: {:error, {:content, :bad_answer}}

  # The plausibility gate (issue #1457): junk is never stored. The checks are
  # deliberately mechanical — the #1455 eval showed they catch a model that
  # lost the thread (collapsed structure, essay-length padding, a "translated"
  # code block) while never tripping on a faithful translation.
  defp vet(answer, body, text, summary) do
    cond do
      String.trim(body) == "" ->
        {:error, {:content, :empty}}

      not plausible_length?(body, text) ->
        {:error, {:content, :length_ratio}}

      fences(body) != fences(text) ->
        {:error, {:content, :fence_changed}}

      summary != nil and String.trim(answer["summary"] || "") == "" ->
        {:error, {:content, :empty_summary}}

      true ->
        {:ok,
         %{
           source_language: source_language(answer),
           body: body,
           summary: summary && answer["summary"],
           model: model()
         }}
    end
  end

  defp plausible_length?(body, text) do
    ratio = String.length(body) / max(String.length(text), 1)
    ratio >= @min_length_ratio and ratio <= @max_length_ratio
  end

  # The fenced blocks, trailing whitespace ignored per block. Compared as a
  # list: count, order and contents must all survive the translation.
  defp fences(text) do
    ~r/```.*?```/s
    |> Regex.scan(text)
    |> Enum.map(fn [block] -> String.trim_trailing(block) end)
  end

  # "und" (undetermined) when the model's tag is garbage: it is a valid ISO
  # 639 tag for exactly this case, and the display layer knows to show no
  # source label for it. Never nil — the row records that detection ran.
  defp source_language(answer) do
    Translations.normalize_language(answer["source_language"]) || "und"
  end

  defp model, do: Application.get_env(:vutuv, :ollama_translation_model, "gemma4:31b")

  # Text inference on the shared box can stall for minutes under contention
  # (`OLLAMA_NUM_PARALLEL=1`); the queue is async, so patience beats a
  # spurious service error.
  defp timeout, do: Application.get_env(:vutuv, :ollama_translation_timeout, 600_000)
end

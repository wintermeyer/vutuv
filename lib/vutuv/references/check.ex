defmodule Vutuv.References.Check do
  @moduledoc """
  One AI check of one Arbeitszeugnis: the durable queue entry while it waits,
  and the stored result once it is done.

  The `Vutuv.Moderation.ImageScan` shape — the row *is* the job — because a
  check takes minutes rather than milliseconds. The member watches this row
  travel from `pending` through `running`, and what they read afterwards is
  the same row.

  `body_fingerprint` binds a result to the exact text that produced it. When
  the member edits the Zeugnis the result is not deleted, it is marked stale:
  the earlier reading is still worth having, it simply no longer describes
  what is on the screen.

  Written only by `Vutuv.References.Checks`; there is no user-facing changeset.
  """

  use VutuvWeb, :model

  alias Vutuv.References.Checks
  alias Vutuv.References.JobReference

  @statuses ~w(pending running done failed canceled)
  @open_statuses ~w(pending running)

  schema "reference_checks" do
    belongs_to(:job_reference, JobReference)
    belongs_to(:user, Vutuv.Accounts.User)

    field(:status, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime)
    field(:last_error, :string)

    field(:body_fingerprint, :string)
    field(:skill_version, :string)
    field(:skill_sha256, :string)
    field(:model, :string)
    field(:result_markdown, :string)

    # The overall grade, settled by the run that produced it rather than
    # re-read from the report on every render. See `grade_span/1`.
    field(:grade_span, :string)

    field(:prompt_tokens, :integer)
    field(:output_tokens, :integer)
    field(:duration_ms, :integer)

    field(:queued_at, :utc_datetime)
    field(:started_at, :utc_datetime)
    field(:finished_at, :utc_datetime)

    # Stamped about once a minute for as long as a worker is really inside the
    # request. Its silence, not the clock, is what marks a check as stranded by
    # a reboot or a deploy — see `Vutuv.References.Checks.resume_stuck/0`.
    field(:heartbeat_at, :utc_datetime)

    timestamps()
  end

  @doc "Every status a check can hold."
  def statuses, do: @statuses

  @doc "The statuses that count as unfinished work (mirrors the partial unique index)."
  def open_statuses, do: @open_statuses

  @doc "Whether this check is still waiting or running."
  def open?(%__MODULE__{status: status}), do: status in @open_statuses

  @doc """
  Whether this result still describes `reference`'s current text.

  A check with no fingerprint predates the text it names and counts as stale;
  so does one whose fingerprint no longer matches.
  """
  def current_for?(
        %__MODULE__{status: "done", body_fingerprint: fingerprint},
        %JobReference{} = reference
      )
      when is_binary(fingerprint) do
    fingerprint == Checks.fingerprint(reference.body)
  end

  def current_for?(%__MODULE__{}, %JobReference{}), do: false

  # The one fact worth repeating in a list row: which grade the Zeugnis reads
  # as. Everything else in the report needs its context, this does not.
  #
  # It is *parsed out of the answer* rather than asked for separately, because
  # a second request would cost another minute of inference and could disagree
  # with the report it sits next to. The model writes the line two ways —
  # a fact bullet and, in a report that leads with a summary table, a table row
  # — so both are matched. A section *heading* carrying the same word is not a
  # value and must not match, or the row would read "mit Begründung".
  # Two spellings, and the **order matters**: "Gesamtnotenspanne" contains
  # "Gesamtnote", so splitting on the short one first would cut the long one
  # mid-word and leave "nspanne:** Note 4 bis 5" as the value. Longest first.
  @grade_keys ["Gesamtnotenspanne", "Gesamtnote"]

  # A row label, not a paragraph. The reasoning is one click away on the result
  # page, so anything past a sentence is cut.
  @grade_max 90

  @doc """
  The overall grade range the review arrived at, as a short line, or nil.

  Nil whenever the answer does not state one in a shape we recognise — better
  no line than a confidently wrong one next to a legal reading.

  Read from the stored column, which `Vutuv.References.Checks` fills once the
  run finishes (`parse_grade_span/1`). Parsing on the fly is the fallback for a
  check that finished before the column existed; nothing else should reach it.
  """
  def grade_span(%__MODULE__{grade_span: span}) when is_binary(span), do: span

  def grade_span(%__MODULE__{result_markdown: markdown}) when is_binary(markdown),
    do: parse_grade_span(markdown)

  def grade_span(_check), do: nil

  @doc """
  Reads the overall grade out of a finished report, or nil.

  Called once per check, by the queue, at the moment the answer arrives. Every
  reader afterwards takes the stored value.
  """
  def parse_grade_span(markdown) when is_binary(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.find_value(&grade_from_line/1)
  end

  def parse_grade_span(_other), do: nil

  @doc """
  Which band the grade falls in — `:good`, `:average`, `:poor`, or nil.

  Read from the first digit in `grade_span/1` ("1 (Sehr Gut …)", "Note 4 bis 5
  (mangelhaft …)", "1–2"), because the number is the one part of that line
  whose meaning is fixed; everything around it is the model's prose. Nil
  whenever no grade digit appears at all, so a line we did not understand is
  shown in neutral grey rather than confidently coloured.

  It only ever **tints a label that already spells the grade out**. Colour must
  not carry the meaning on its own (WCAG 1.4.1), and here it doubly must not:
  the value behind it was parsed out of a language model's answer, so the
  member has to be able to read the verdict and disbelieve the colour.
  """
  def grade_band(%__MODULE__{} = check), do: check |> grade_span() |> band_from_span()

  defp band_from_span(nil), do: nil

  defp band_from_span(span) do
    case Regex.run(~r/[1-6]/, span) do
      ["1"] -> :good
      ["2"] -> :good
      ["3"] -> :average
      [_worse] -> :poor
      nil -> nil
    end
  end

  defp grade_from_line(line) do
    trimmed = String.trim(line)

    cond do
      # A heading names the section, not the verdict — and one of the report's
      # own headings is literally "Gesamtnotenspanne mit Begründung".
      String.starts_with?(trimmed, "#") -> nil
      is_nil(key_in(trimmed)) -> nil
      String.starts_with?(trimmed, "|") -> grade_from_table_row(trimmed)
      true -> grade_from_fact_line(trimmed)
    end
  end

  defp key_in(line), do: Enum.find(@grade_keys, &String.contains?(line, &1))

  # `| **Gesamtnotenspanne** | Note 4 bis 5 |` -> the next non-empty cell.
  defp grade_from_table_row(line) do
    key = key_in(line)

    line
    |> String.split("|", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.drop_while(&(not String.contains?(&1, key)))
    |> Enum.drop(1)
    |> Enum.find(&(&1 != ""))
    |> tidy_grade()
  end

  # Two shapes reach here:
  #   `*   **Gesamtnotenspanne:** Note 4 bis 5 (…). Es handelt sich …`
  #   `**Gesamtnote: 1 (Sehr Gut / Hervorragend)**`
  defp grade_from_fact_line(line) do
    case String.split(line, key_in(line), parts: 2) do
      [_before, rest] -> rest |> String.trim_leading(":*  ") |> first_sentence() |> tidy_grade()
      _no_split -> nil
    end
  end

  # The value is the first sentence; the rest of the bullet argues for it.
  # Split on ". " rather than "." so "Note 4 bis 5 (…)." keeps its parenthesis
  # and an abbreviation mid-sentence does not cut it short.
  defp first_sentence(text) do
    case String.split(text, ". ", parts: 2) do
      [head, _tail] -> head
      [whole] -> String.trim_trailing(whole, ".")
    end
  end

  defp tidy_grade(nil), do: nil

  defp tidy_grade(text) do
    cleaned =
      text
      |> String.replace("**", "")
      |> String.replace("*", "")
      |> String.trim()
      |> String.trim_leading(":")
      |> String.trim()

    cond do
      cleaned == "" -> nil
      String.length(cleaned) > @grade_max -> String.slice(cleaned, 0, @grade_max) <> "…"
      true -> cleaned
    end
  end
end

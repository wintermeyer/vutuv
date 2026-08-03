defmodule Vutuv.References.GradeSpanTest do
  @moduledoc """
  Pulling the overall grade out of the review, for the one line the list row
  shows.

  Every input here is a real shape the model produced, not an invented one.
  The parser has to stay conservative: a wrong grade beside a Zeugnis is worse
  than no grade, so anything it does not recognise must come back nil.
  """
  use ExUnit.Case, async: true

  alias Vutuv.References.Check

  defp check(markdown), do: %Check{status: "done", result_markdown: markdown}

  # The extracted line is a label in a table row, not a sentence, so the
  # closing period is dropped.

  describe "the shapes the model really writes" do
    test "a fact bullet" do
      md = """
      ### Kurzbefund und Ampel-Bilanz

      *   **Zeugnisart:** Qualifiziertes Arbeitszeugnis (§ 109 GewO).
      *   **Gesamtnotenspanne:** Note 4 bis 5 (mangelhaft bis ungenügend). Es handelt sich um ein schlechtes Zeugnis mit deutlichen negativen Codes.
      *   **Ampel-Bilanz:** 🔴 6 · 🟠 2 · 🟢 0
      """

      assert Check.grade_span(check(md)) == "Note 4 bis 5 (mangelhaft bis ungenügend)"
    end

    test "a summary table row" do
      md = """
      | Merkmal | Befund |
      | :--- | :--- |
      | **Zeugnisart** | Qualifiziertes Arbeitszeugnis |
      | **Gesamtnotenspanne** | **Note 4 (ausreichend)** bis **Note 5 (mangelhaft)** |
      """

      assert Check.grade_span(check(md)) == "Note 4 (ausreichend) bis Note 5 (mangelhaft)"
    end

    # A third shape, from a real report: the verdict as a standalone bold line
    # under its own heading, and spelled "Gesamtnote" rather than
    # "Gesamtnotenspanne".
    test "a standalone bold verdict line" do
      md = """
      ### 2. Gesamtnotenspanne mit Begründung

      **Gesamtnote: 1 (Sehr Gut / Hervorragend)**

      Das Zeugnis verwendet durchgehend Maximalformeln.
      """

      assert Check.grade_span(check(md)) == "1 (Sehr Gut / Hervorragend)"
    end

    # "Gesamtnotenspanne" contains "Gesamtnote". Splitting on the short key
    # first would cut the long word mid-way and leave "nspanne:** Note 4 …".
    test "the longer spelling is not cut in half by the shorter one" do
      md = "*   **Gesamtnotenspanne:** Note 4 bis 5 (mangelhaft)."

      span = Check.grade_span(check(md))
      assert span == "Note 4 bis 5 (mangelhaft)"
      refute span =~ "nspanne"
    end

    # The reasoning belongs on the result page, not in a list row.
    test "keeps the verdict and drops the argument after it" do
      md =
        "*   **Gesamtnotenspanne:** Note 3 bis Note 4. " <>
          "Das Zeugnis ist bewusst unauffällig und vermeidet sowohl Lob als auch Kritik."

      assert Check.grade_span(check(md)) == "Note 3 bis Note 4"
    end

    test "caps a verdict that runs on" do
      md = "*   **Gesamtnotenspanne:** " <> String.duplicate("Note 3 bis 4 ", 20)

      span = Check.grade_span(check(md))
      assert String.length(span) <= 91
      assert String.ends_with?(span, "…")
    end
  end

  describe "what must not match" do
    # The report has a section called "Gesamtnotenspanne mit Begründung". A
    # heading names the section, not the verdict; matching it would put "mit
    # Begründung" in the row where a grade belongs.
    test "a section heading" do
      md = """
      ### 2. Gesamtnotenspanne mit Begründung

      Die Leistungsbewertung trägt eine Note 4.
      """

      assert Check.grade_span(check(md)) == nil
    end

    test "an answer that never states one" do
      assert Check.grade_span(check("## Befund\n\nDas Zeugnis ist unauffällig.")) == nil
    end

    test "an empty value" do
      assert Check.grade_span(check("*   **Gesamtnotenspanne:**")) == nil
      assert Check.grade_span(check("| **Gesamtnotenspanne** |  |")) == nil
    end

    test "a check with no result at all" do
      assert Check.grade_span(%Check{status: "pending", result_markdown: nil}) == nil
      assert Check.grade_span(%Check{}) == nil
    end
  end

  # The band only tints a label that already spells the grade out in words, so
  # the cost of getting it wrong is a misleading colour beside a correct
  # sentence — but a Zeugnis tinted green when it grades 4 would still be the
  # worst thing this page could do, so nil is the answer whenever the line
  # holds no grade digit at all.
  describe "grade_band/1" do
    test "reads the band off the first grade digit" do
      assert Check.grade_band(check("**Gesamtnote: 1 (Sehr Gut)**")) == :good
      assert Check.grade_band(check("**Gesamtnote: 2 (Gut)**")) == :good
      assert Check.grade_band(check("**Gesamtnote: 3 (Befriedigend)**")) == :average
      assert Check.grade_band(check("**Gesamtnote: 5 (ungenügend)**")) == :poor
    end

    test "a range takes its best grade, which is the one stated first" do
      assert Check.grade_band(check("*   **Gesamtnotenspanne:** 1–2 (sehr gut)")) == :good

      assert Check.grade_band(check("*   **Gesamtnotenspanne:** Note 4 bis 5 (mangelhaft)")) ==
               :poor
    end

    test "no grade digit, no colour" do
      assert Check.grade_band(check("**Gesamtnote: nicht bestimmbar**")) == nil
      assert Check.grade_band(check("## Befund\n\nunauffällig.")) == nil
      assert Check.grade_band(%Check{}) == nil
    end
  end

  describe "the heading and the value in one report" do
    # The real answers carry both: the bullet up top and a section further
    # down. The bullet must win, and it comes first.
    test "takes the fact bullet, not the later heading" do
      md = """
      *   **Gesamtnotenspanne:** Note 4 bis 5 (mangelhaft).

      ### 2. Gesamtnotenspanne mit Begründung

      Ausführliche Herleitung.
      """

      assert Check.grade_span(check(md)) == "Note 4 bis 5 (mangelhaft)"
    end
  end
end

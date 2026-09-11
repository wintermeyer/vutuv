defmodule Vutuv.Uploads.PdfGate do
  @moduledoc """
  What a PDF has to be before this installation keeps it (issue #2104).

  There is no virus scanner behind this; the format whitelist and this gate
  are the defence, so it **fails closed**. Anything it cannot decide — poppler
  missing, poppler failing, a scan it could not finish — is a refusal, never a
  pass.

  It lives under `Vutuv.Uploads` rather than under the context that added it
  because two other doors already take a member's PDF and hand it back
  verbatim — `Vutuv.QualificationDocument` and `Vutuv.JobReferenceDocument`,
  whose only check is that page 1 renders. Neither calls this yet; putting it
  here is what makes that a one-line change rather than a context dependency.

  ## The four effects it blocks

    * **The file cannot be read** (an encrypted PDF). `pdfinfo` exits non-zero
      with *"Incorrect password"* for a user password and answers
      `Encrypted: yes` for an owner-password-only file, which is readable but
      restricted. Both are refused: nothing downstream — the page previews of
      #2105, the metadata cleaning of #2107 — can work on a file it cannot open.
    * **It runs code when it is opened** — `pdfinfo`'s own `JavaScript:` field.
    * **It does something to the reader when it is opened** — an `/OpenAction`
      that is an *action* rather than a destination, and an action that reaches
      outside the document at all (`/Launch`, `/SubmitForm`, `/ImportData`)
      wherever it stands. The second half is not decoration: the same effect
      rides a page's `/AA` and an `/OpenAction`'s chained `/Next` under names
      the `/OpenAction` rule never looks at.
    * **It carries another file inside it** — `pdfdetach -list`, which counts
      them.

  ## Names are structure, words are not (issue #2136)

  A PDF **name** (`/Launch`) is structure. A PDF **string** (`(Launch)`) is
  content: every visible character a document shows is drawn out of one, and so
  is every title, bookmark and link target. Reading both alike refused a CV for
  listing web skills — two macOS-produced PDFs whose text said
  "TypeScript/JavaScript" came back `:javascript` while `pdfinfo` said
  `JavaScript: no`.

  So a string literal, a hex string and a comment are blanked out of every
  buffer before the names are looked for, byte for byte, so that the offsets
  the `/OpenAction` rule reads afterwards still line up. Blanking cannot lose
  an action a reader would run: inside a balanced string a name is a string,
  here and in every parser alike. The one way it could is an **object stream**,
  where a reader picks each object out at the offset the stream's own table
  records rather than reading front to back, so a `(` planted in one object and
  a `)` in the next would blank the catalog between them. That is why a
  candidate range spanning a `<<` or a `>>` is **not** blanked: everything
  dangerous on the far side of an object boundary is a dictionary, so a range
  holding one has not proven itself content and stays in the scan. An
  unterminated `(` is likewise left as the byte it is.

  The cheaper fix considered and not taken was to anchor each name on what must
  stand beside it — `/S` before `/Launch`, `<<` or `[` after `/OpenAction` —
  since no prose writes `/S /Launch`. It would have cost none of this code and
  would also cover the XMP case below. It was passed over because it enumerates
  a spelling rather than naming the effect: the anchor has to be re-guessed for
  every name added, and a file is free to put a comment, an indirect reference
  or 200 bytes of whitespace between the two halves. Blanking says what is
  actually true — a string is not structure — and errs toward refusing.

  ## Which question is asked of whom, measured

  Blanking is not enough on its own, because a document's words also reach the
  file outside PDF syntax — an XMP metadata packet is XML, so
  `<dc:title>…HTML/CSS/JavaScript</dc:title>` is not a string this can blank
  (Ghostscript wrote exactly that, measured 2026-09-11). What settles it is
  which question a **parser** can answer, and that is measured rather than
  assumed:

    * **JavaScript: poppler, alone.** `pdfinfo` answers `JavaScript: yes` for a
      script in the catalog's `/Names /JavaScript` tree, in `/OpenAction`, in
      the catalog's `/AA`, in a page's `/AA` and on an annotation's `/A` alike
      (2026-09-11). It sees through object streams and incremental updates, and
      a byte scan that cannot tell a title from a script has no business voting
      beside it. `/JavaScript` is therefore **not** one of the names below.
    * **Embedded files: poppler *and* the bytes.** `pdfdetach -list` counts a
      file in the `/EmbeddedFiles` name tree, in a `/Collection`, and on a
      `/FileAttachment` annotation with or without its `/Type /EmbeddedFile` —
      but answers **0** for a filespec reached through `/AF` on the catalog,
      through `/AF` on a page, or through a `/RichMedia` annotation's assets
      (all measured 2026-09-11). So `/EmbeddedFile` stays in the byte scan,
      which is what catches those three. No ordinary document writes that word.
    * **An action: the bytes, alone.** No poppler tool reports `/OpenAction`, so
      it and the three acting names are read from the file and from every
      stream that inflates — one `qpdf --object-streams=generate` run moves
      every dictionary into a Flate-compressed object stream, after which a
      plain grep finds nothing in a file that still does the same thing
      (`grep -ac` said 0, checked 2026-09-10).

  Both gates were run end to end over 4,542 real local PDFs on 2026-09-11: ten
  answers changed, nine of them a refusal lifted and one refused for a
  different reason, and **none** newly refused. The one pre-existing document
  among the nine is a 312-page programming book that was refused for linking to
  `developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/…` from a `/URI`
  action.

  ## Where the set is not closed

  A stream whose filter is not zlib-compatible — LZW, RunLength, a filter
  cascade, or a `/Crypt` filter — is skipped by the inflation pass, so an
  `/OpenAction` inside such a stream would not be seen. No producer writes an
  object stream that way (object streams exist to be Flate-compressed, and an
  encrypted file is refused before this runs), but the possibility is real and
  named here rather than pretended away.

  An `/AcroForm /XFA` form carries its script in an XML stream rather than in a
  PDF action, and neither poppler's `JavaScript:` field nor any of these names
  sees it (measured 2026-09-11). Refusing XFA outright would refuse the
  interactive government forms people do attach, so it is named here and left
  to a decision of its own.

  An embedded file reached through `/AF` or `/RichMedia` whose stream *also*
  drops its `/Type /EmbeddedFile` is seen by nothing here: poppler does not
  count it and there is no name left to match. Closing that would mean refusing
  `/EF` or `/Filespec` outright, which is a widening with a cost of its own and
  wants measuring first.

  `/AA` (additional actions) is deliberately **not** blocked as a name: it sits
  on the widgets of every ordinary form, and it appeared in 2 of 1,051 real
  PDFs measured on 2026-09-10. What is blocked is the *action* inside it — see
  `@acting_names` — so a page whose `/AA` opens a calculator is refused while a
  form's widgets are not.
  """

  require Logger

  # The inflation pass's budget, per stream and in total. Past either one the
  # scan is incomplete, and an incomplete scan refuses — a stream nobody could
  # read is not a stream anybody proved harmless. Measured over 1,051 real,
  # local PDFs on 2026-09-10: the largest single inflated stream is 3 MB and
  # the largest whole-file total is under 96 MB, so both cuts sit well clear of
  # an ordinary document while a bomb still stops at them.
  @stream_limit 8_000_000
  @total_limit 96_000_000

  # How far a `(` may reach before this stops believing it opened a string, and
  # equally how far a `<` may sit from its `>`. A cost bound rather than a
  # judgement: past it the bytes are scanned as what they are, which can only
  # refuse more, and without it a buffer of nothing but brackets would make the
  # blanking pass quadratic.
  @string_limit 65_536

  # Actions that do something to the *machine* rather than move the reader
  # inside the document, refused wherever they stand. Naming the effect rather
  # than one spelling of it: leaving these out let two files through that the
  # `/OpenAction` rule was meant to stop, because neither is an `/OpenAction`
  # that is an action — an `/OpenAction << /S /GoTo … /Next << /S /Launch >> >>`,
  # whose `/GoTo` prefix satisfies `destination?/1` and whose chained second
  # half nothing looked at, and a page `/AA << /O << /S /Launch >> >>`, which
  # fires on the same event under a different name. `pdfinfo` answers
  # `JavaScript: no` for both. Measured over 1,051 real, local PDFs on
  # 2026-09-10: `/Launch`, `/SubmitForm` and `/ImportData` appear in **none** of
  # them, so naming them costs no ordinary document.
  @acting_names ~w(Launch SubmitForm ImportData)

  # The names, with `#XX` escapes allowed for every character — one pass that
  # matches `/OpenAction` and `/Open#41ction` alike, so nothing has to decode a
  # 20 MB buffer to find the second spelling. No `u` modifier anywhere in this
  # module: these patterns run over slices of a PDF, which are not text.
  #
  # `/JavaScript` is deliberately **not** in this list — see the moduledoc:
  # poppler answers that question from the parsed document, wherever the script
  # hangs, and a name that is also an ordinary English word in a document title
  # cost a CV its upload. `/EmbeddedFile` is still here because poppler's answer
  # has three measured gaps.
  @name_regexes (for name <- ["EmbeddedFile", "OpenAction" | @acting_names], into: %{} do
                   pattern =
                     "/" <>
                       Enum.map_join(String.to_charlist(name), fn char ->
                         hex = char |> Integer.to_string(16) |> String.pad_leading(2, "0")
                         "(?:" <> <<char>> <> "|#(?i:" <> hex <> "))"
                       end)

                   {name, Regex.compile!(pattern)}
                 end)

  # The same names in one alternation, for the cheap question asked first: is
  # there anything here to argue about at all?
  @any_name_regex @name_regexes
                  |> Map.values()
                  |> Enum.map_join("|", &Regex.source/1)
                  |> Regex.compile!()

  # `stream` … `endstream`, bytes rather than characters (no `u` modifier, so
  # `.` matches any byte and a slice of a PDF cannot break the match).
  @stream_regex ~r/stream\r?\n(.*?)endstream/s

  # What may follow an `/OpenAction`: a destination array, or a dictionary
  # whose action is `/GoTo` — a jump inside this same document. That is what
  # hyperref's `pdfstartview` and Word write, and refusing it would refuse
  # ordinary academic PDFs for nothing.
  @destination_regex ~r/\A\s*\[/
  @goto_regex ~r/\A\s*<<[^>]{0,400}?\/S\s*\/GoTo[\s\/>]/

  @doc """
  Reads the PDF at `path` and answers `{:ok, page_count}` or
  `{:error, :encrypted | :javascript | :open_action | :embedded_files |
  :unreadable}`.
  """
  def check(path) do
    with {:ok, info} <- pdfinfo(path),
         :ok <- refuse_if(info, ~r/^Encrypted:\s+yes/m, :encrypted),
         :ok <- refuse_if(info, ~r/^JavaScript:\s+yes/m, :javascript),
         :ok <- embedded_files(path),
         :ok <- scan_bytes(path) do
      {:ok, page_count(info)}
    end
  end

  @doc """
  Whether this installation can check PDFs at all: both poppler tools on
  `$PATH`. Probed once per VM, like `Vutuv.Videos`' ffmpeg answer — without
  them PDFs are simply not offered, and text and Markdown carry on.
  """
  def available? do
    case :persistent_term.get({__MODULE__, :available}, :unknown) do
      :unknown ->
        verdict =
          System.find_executable(tool(:pdfinfo)) != nil and
            System.find_executable(tool(:pdfdetach)) != nil

        :persistent_term.put({__MODULE__, :available}, verdict)
        verdict

      verdict ->
        verdict
    end
  end

  @doc "Drops the cached probe — the tests move the configured binary around."
  def forget_capability, do: :persistent_term.erase({__MODULE__, :available})

  ## poppler

  defp pdfinfo(path) do
    case run(:pdfinfo, [path]) do
      {out, 0} ->
        {:ok, out}

      {out, _status} ->
        # A user password stops poppler at the door: "Command Line Error:
        # Incorrect password". Everything else is a file we could not read,
        # which is equally a refusal — just a different sentence for the member.
        if out =~ "password", do: {:error, :encrypted}, else: refused(:unreadable, out)
    end
  end

  defp embedded_files(path) do
    case run(:pdfdetach, ["-list", path]) do
      {out, 0} ->
        case Regex.run(~r/^\s*(\d+)\s+embedded files?/mi, out) do
          [_all, "0"] -> :ok
          [_all, _some] -> {:error, :embedded_files}
          # It answered, but not in a shape we know. We cannot say there are
          # none, so we do not.
          nil -> refused(:unreadable, out)
        end

      {out, _status} ->
        refused(:unreadable, out)
    end
  end

  defp run(name, args) do
    System.cmd(tool(name), args, stderr_to_stdout: true)
  rescue
    exception -> {Exception.message(exception), :crashed}
  catch
    :exit, reason -> {inspect(reason), :exit}
  end

  defp tool(name) do
    :vutuv |> Application.get_env(:attachments, []) |> Keyword.get(name, to_string(name))
  end

  defp refuse_if(info, regex, reason), do: if(info =~ regex, do: {:error, reason}, else: :ok)

  defp refused(reason, output) do
    Logger.info("attachment pdf gate refused (#{reason}): #{String.slice(output, 0, 200)}")
    {:error, reason}
  end

  defp page_count(info) do
    case Regex.run(~r/^Pages:\s+(\d+)/m, info) do
      [_all, count] -> String.to_integer(count)
      nil -> nil
    end
  end

  ## The byte scan

  defp scan_bytes(path) do
    bytes = File.read!(path)

    with :ok <- scan_buffer(bytes) do
      bytes |> streams() |> scan_streams(0)
    end
  end

  defp scan_streams([], _spent), do: :ok

  defp scan_streams(_streams, spent) when spent >= @total_limit do
    # The scan could not be finished, so it did not pass.
    {:error, :unreadable}
  end

  defp scan_streams([{bytes, start, length} | rest], spent) do
    case inflate(binary_part(bytes, start, length)) do
      # A stream this could not finish inflating is a stream it did not scan,
      # and an unfinished scan refuses — the same answer `@total_limit` gives.
      # Skipping it instead was an exemption that cannot be proven: padding a
      # catalog to 9 MB and running one `qpdf --object-streams=generate` puts
      # `/OpenAction << /S /Launch >>` in a 9.5 KB file that inflates past the
      # cut, and the scan walked straight past it. Measured over 1,051 real,
      # local PDFs on 2026-09-10: the largest single inflated stream in the
      # whole corpus is 3 MB and **none** reaches 4 MB, so the cut costs no
      # ordinary document.
      :too_big -> {:error, :unreadable}
      # Not zlib at all — a JPEG, a font, an encrypted payload. There is
      # nothing to inflate, so there is nothing this pass could have read; the
      # filter that makes such a stream unreadable here is named in the
      # moduledoc as the place the set is not closed.
      :error -> scan_streams(rest, spent)
      {:ok, out} -> scan_inflated(out, rest, spent)
    end
  end

  defp scan_inflated(out, rest, spent) do
    case scan_buffer(out) do
      :ok -> scan_streams(rest, spent + byte_size(out))
      error -> error
    end
  end

  # The blanking is part of the scan rather than something each caller pipes in
  # front of it: a buffer this has not read as syntax is a buffer it has read as
  # text, and that is the bug this module was fixed for.
  #
  # It is also the expensive half — blanking a 22 MB file costs 411 ms against
  # 21 ms for the names themselves (measured over 12 real PDFs on 2026-09-11) —
  # so it runs only where it could change the answer. A name that is not in the
  # raw bytes cannot be in the blanked ones, because blanking only ever removes,
  # and not one of those 12 documents carries any of these names at all.
  defp scan_buffer(raw) do
    if Regex.match?(@any_name_regex, raw), do: scan_syntax(without_content(raw)), else: :ok
  end

  defp scan_syntax(buffer) do
    cond do
      Regex.match?(@name_regexes["EmbeddedFile"], buffer) -> {:error, :embedded_files}
      acting?(buffer) or open_action?(buffer) -> {:error, :open_action}
      true -> :ok
    end
  end

  defp acting?(buffer),
    do: Enum.any?(@acting_names, &Regex.match?(@name_regexes[&1], buffer))

  defp open_action?(buffer) do
    @name_regexes["OpenAction"]
    |> Regex.scan(buffer, return: :index)
    |> Enum.any?(fn [{start, length} | _] ->
      after_name = start + length
      rest = binary_part(buffer, after_name, min(512, byte_size(buffer) - after_name))
      not destination?(rest)
    end)
  end

  defp destination?(rest),
    do: Regex.match?(@destination_regex, rest) or Regex.match?(@goto_regex, rest)

  # Where each stream's payload *starts*, never a copy of it: `capture:
  # :all_but_first` would allocate a fresh binary per stream, which on a PDF
  # that is mostly stream data doubles the memory this holds while it scans.
  # `binary_part/3` on the original hands back a sub-binary instead.
  #
  # The slice runs from the `stream` marker to the **end of the file**, not to
  # the next literal `endstream`: `endstream` is not a trustworthy terminator,
  # because a stream's payload is arbitrary bytes an attacker chooses. A stored
  # (uncompressed) deflate block can carry the nine bytes `endstream` ahead of
  # a compressed `/OpenAction << /S /Launch >>`, and a scan that stopped the
  # capture at that literal would inflate only the decoy prefix and never see
  # the action. `:zlib` stops at the deflate stream's own end marker and
  # ignores every trailing byte, so handing it the rest of the file reads the
  # whole real stream and no more.
  defp streams(bytes) do
    total = byte_size(bytes)

    @stream_regex
    |> Regex.scan(bytes, return: :index, capture: :all_but_first)
    |> Enum.map(fn [{start, _length}] -> {bytes, start, total - start} end)
  end

  ## Syntax, not text

  # Replaces every string literal, hex string and comment with the same number
  # of blanks. What a page shows is drawn out of strings, and so are titles,
  # bookmarks and link targets, so `/JavaScript` in `(HTML/CSS/JavaScript)` and
  # `/Launch` in `(…/products/Launch)` are words rather than actions — for this
  # scan and for every parser that reads the same file.
  defp without_content(buffer) do
    # Compiled once and carried down: `:binary.match/3` builds a fresh
    # Aho-Corasick automaton for every literal *list* it is handed, which over a
    # 20 MB file is 400,000 rebuilds and two thirds of this pass (407 ms against
    # 138 ms precompiled, measured 2026-09-11). A compiled pattern is a
    # reference, so it cannot be a module attribute.
    patterns = {
      :binary.compile_pattern(["(", "<<", "<", "%"]),
      :binary.compile_pattern(["(", ")", "\\"]),
      :binary.compile_pattern(["\n", "\r"]),
      :binary.compile_pattern(["<<", ">>"])
    }

    {parts, cursor} =
      buffer
      |> content_ranges(0, [], patterns)
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn {start, length}, {acc, cursor} ->
        {[blanks(length), binary_part(buffer, cursor, start - cursor) | acc], start + length}
      end)

    IO.iodata_to_binary(
      Enum.reverse([binary_part(buffer, cursor, byte_size(buffer) - cursor) | parts])
    )
  end

  # A sub-binary of one shared run rather than a fresh copy per range: a 20 MB
  # file yields ~22,000 ranges holding 11 MB between them, and none of it needs
  # to be allocated twice.
  @blanks :binary.copy(" ", 4096)
  defp blanks(length) when length <= 4096, do: binary_part(@blanks, 0, length)
  defp blanks(length), do: :binary.copy(" ", length)

  # Descending, so the caller reverses once. Every branch resumes at or past the
  # last byte it read, which is what keeps the pass linear — see
  # `blank_unless_dictionary/5`.
  defp content_ranges(buffer, from, acc, patterns) do
    size = byte_size(buffer)

    if from >= size do
      acc
    else
      # Leftmost-longest, so `<<` is read as a dictionary opening rather than as
      # a hex string that would swallow the dictionary's first key.
      case :binary.match(buffer, elem(patterns, 0), scope: {from, size - from}) do
        :nomatch -> acc
        {at, 2} -> content_ranges(buffer, at + 2, acc, patterns)
        {at, 1} -> content_range(:binary.at(buffer, at), buffer, at, acc, patterns)
      end
    end
  end

  defp content_range(?(, buffer, at, acc, patterns) do
    case literal_end(buffer, at + 1, at, 1, patterns) do
      {:ok, stop} -> blank_unless_dictionary(buffer, at, stop, acc, patterns)
      {:none, resume} -> content_ranges(buffer, resume, acc, patterns)
    end
  end

  defp content_range(?<, buffer, at, acc, patterns) do
    # Bounded rather than "wherever the next `>` is": an unclosed `<` in the
    # middle of a stream's bytes must not cost a scan of the rest of the file.
    reach = min(@string_limit, byte_size(buffer) - at - 1)

    case :binary.match(buffer, ">", scope: {at + 1, reach}) do
      {stop, _length} -> blank_unless_dictionary(buffer, at, stop + 1, acc, patterns)
      :nomatch -> content_ranges(buffer, at + reach, acc, patterns)
    end
  end

  defp content_range(?%, buffer, at, acc, patterns) do
    size = byte_size(buffer)

    stop =
      case :binary.match(buffer, elem(patterns, 2), scope: {at, size - at}) do
        {eol, _length} -> eol
        :nomatch -> size
      end

    blank_unless_dictionary(buffer, at, stop, acc, patterns)
  end

  # A blanked range is an **exemption** from the scan, and an exemption that
  # cannot be proven does not apply. What proves it is that the range holds no
  # dictionary: a linear reader and a real parser part company only across an
  # object boundary — inside an object stream a reader picks each object out at
  # the offset the stream's own table records — and every dangerous thing on the
  # other side of such a boundary is a dictionary (`/OpenAction << … >>`,
  # `<< /S /Launch >>`). So a candidate string that spans a `<<` or a `>>` is
  # left in place and scanned as it stands, which can only refuse more. Without
  # this, a `(` in one object of an object stream and a `)` in the next would
  # blank the catalog between them.
  #
  # Either way the scan resumes **past** the range rather than one byte into it.
  # Starting over inside it is what a file can exploit: 60 KB of `%` with a `<<`
  # behind them and one `/Launch` to arm the pass took 2.8 seconds of a
  # LiveView's own process, quadrupling with every doubling, which puts a file
  # at the 20 MB cap in the region of days (measured 2026-09-11). Skipping the
  # candidates inside a range this would not exempt anyway only ever blanks
  # less, which only ever refuses more.
  defp blank_unless_dictionary(buffer, at, stop, acc, patterns) do
    range = binary_part(buffer, at, stop - at)

    acc =
      if :binary.match(range, elem(patterns, 3)) == :nomatch,
        do: [{at, stop - at} | acc],
        else: acc

    content_ranges(buffer, stop, acc, patterns)
  end

  # `\` escapes the next byte and `(` nests, exactly as a reader parses it:
  # anything else would let one file mean two things. An unterminated string is
  # not a string, so the scan carries on through the `(` — and past the stretch
  # it just read.
  defp literal_end(buffer, from, start, depth, patterns) do
    size = byte_size(buffer)

    if from >= size do
      {:none, size}
    else
      case :binary.match(buffer, elem(patterns, 1), scope: {from, size - from}) do
        :nomatch -> {:none, size}
        {at, _length} when at - start > @string_limit -> {:none, at}
        {at, _length} -> literal_step(:binary.at(buffer, at), buffer, at, start, depth, patterns)
      end
    end
  end

  defp literal_step(?\\, buffer, at, start, depth, patterns),
    do: literal_end(buffer, at + 2, start, depth, patterns)

  defp literal_step(?(, buffer, at, start, depth, patterns),
    do: literal_end(buffer, at + 1, start, depth + 1, patterns)

  defp literal_step(?), _buffer, at, _start, 1, _patterns), do: {:ok, at + 1}

  defp literal_step(?), buffer, at, start, depth, patterns),
    do: literal_end(buffer, at + 1, start, depth - 1, patterns)

  ## zlib

  # Inflates one stream, stopping at `@stream_limit` rather than letting a
  # deliberately tiny deflate stream expand into gigabytes.
  defp inflate(payload) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z)
      collect(z, payload, [], 0)
    rescue
      _ -> :error
    catch
      _kind, _reason -> :error
    after
      :zlib.close(z)
    end
  end

  defp collect(z, input, acc, size) do
    case :zlib.safeInflate(z, input) do
      {:continue, output} -> continue(z, output, acc, size)
      {:finished, output} -> {:ok, IO.iodata_to_binary([acc, output])}
    end
  end

  defp continue(z, output, acc, size) do
    size = size + IO.iodata_length(output)

    if size > @stream_limit,
      do: :too_big,
      else: collect(z, [], [acc, output], size)
  end
end

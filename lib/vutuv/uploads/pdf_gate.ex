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

  ## Why a raw-byte scan is not enough, measured

  The obvious implementation greps the file for `/JavaScript`, `/OpenAction`
  and `/EmbeddedFile`. One `qpdf --object-streams=generate` run defeats all
  three: every dictionary moves into a Flate-compressed object stream and the
  three strings are simply not in the file any more (`grep -ac` says 0 for
  each, checked on 2026-09-10), while the document goes on doing exactly what
  it did.

  So the two questions poppler can answer are asked of **poppler**, which
  parses the structure and sees through object streams. The one it cannot —
  `/OpenAction` — is asked of the raw bytes **and of every stream this can
  inflate**, and since that pass is running anyway it looks for the other two
  names as well; removing the inflation leaves only the `/OpenAction` case
  red, which is how the test calibrates it. `#XX` escapes are tolerated,
  because `/Open#41ction` is the same name to a reader.

  ## Where the set is not closed

  A stream whose filter is not zlib-compatible — LZW, RunLength, a filter
  cascade, or a `/Crypt` filter — is skipped by the inflation pass, so an
  `/OpenAction` inside such a stream would not be seen. No producer writes an
  object stream that way (object streams exist to be Flate-compressed, and an
  encrypted file is refused before this runs), but the possibility is real and
  named here rather than pretended away.

  `/AA` (additional actions) is deliberately **not** blocked as a name: it sits
  on the widgets of every ordinary form, and it appeared in 2 of 1,051 real
  PDFs measured on this machine on 2026-09-10. What is blocked is the *action*
  inside it — see `@acting_names` — so a page whose `/AA` opens a calculator is
  refused while a form's widgets are not.
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
  @name_regexes (for name <- ~w(JavaScript EmbeddedFile OpenAction) ++ @acting_names,
                     into: %{} do
                   pattern =
                     "/" <>
                       Enum.map_join(String.to_charlist(name), fn char ->
                         hex = char |> Integer.to_string(16) |> String.pad_leading(2, "0")
                         "(?:" <> <<char>> <> "|#(?i:" <> hex <> "))"
                       end)

                   {name, Regex.compile!(pattern)}
                 end)

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

  defp scan_buffer(buffer) do
    cond do
      Regex.match?(@name_regexes["JavaScript"], buffer) -> {:error, :javascript}
      Regex.match?(@name_regexes["EmbeddedFile"], buffer) -> {:error, :embedded_files}
      acting?(buffer) -> {:error, :open_action}
      open_action?(buffer) -> {:error, :open_action}
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

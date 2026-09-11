defmodule Vutuv.Attachments.Metadata do
  @moduledoc """
  The one place vutuv talks to `qpdf` (issue #2107): taking the author's name,
  the software that wrote it and the dates out of a PDF before anybody can
  download it.

  ## Two copies, and which one is rewritten

  `Vutuv.AttachmentStore` keeps every file twice — the verbatim upload under
  `originals/` and the copy a reader is handed under `attachments/`. **Only
  the served copy is ever rewritten.** The private tree's promise is that what
  the member sent is kept exactly as they sent it, which is also what makes
  this operation reversible: the served copy is a *derivation* of the original
  under the author's answer, so `strip/2` and `restore/1` can be run any
  number of times in any order and the result is the same.

  ## When it runs

  At intake, on every PDF, before the author has answered — because the answer
  defaults to yes and the parent milestone (#2102) wants a file *cleaned* by
  the time its post publishes, beside its preview pages and its AI check. The
  switch turning it off then costs a `File.cp` from the original at claim time
  (`Vutuv.Attachments.apply_metadata_choice/1`) rather than a shell-out on the
  publish path.

  ## The flags, and what they leave behind

      qpdf --remove-info --remove-metadata --deterministic-id --linearize

  `--remove-info` empties the trailer's `/Info` dictionary (Title, Author,
  Creator, Producer, CreationDate, Subject, Keywords) and `--remove-metadata`
  drops the catalog's XMP packet (`dc:creator`, `xmp:CreatorTool`,
  `xmp:CreateDate`). `--deterministic-id` replaces the trailer's `/ID`, which
  is otherwise derived from the writing machine's clock and file path, with a
  hash of the content. `--linearize` writes a web-optimised file, and rewriting
  it at all is what drops any incremental-update history — the earlier
  revisions of a document, which are where a "redacted" paragraph usually
  still is.

  Two deliberate departures from the obvious maximum:

    * **`/ModDate` survives.** qpdf's `--remove-info` keeps it on purpose
      (documented: "except modification date"). Removing it needs
      `--empty --pages in.pdf 1-z --`, which rebuilds the document from its
      pages alone and drops the outline, the page labels and the named
      destinations with it. A thesis silently losing its bookmarks is a worse
      trade than a surviving modification date, and the author who disagrees
      has the switch.
    * **`--remove-structure` is not used.** It removes the *tagged-PDF
      structure tree*, which is what a screen reader follows. That is an
      accessibility feature, not metadata.

  ## The version this needs, and why the probe runs a command

  `--remove-info` and `--remove-metadata` arrived in **qpdf 11.10.0**
  (2025-02-08); `--deterministic-id` (6.0.0) and `--linearize` are far older.
  Production runs Debian stable's 12.2.0 and is fine, but plenty of boxes are
  not: **Debian 12 ships 11.3.0 and Ubuntu 24.04 ships 11.9.0**, both of which
  have the binary and neither of which has the flags.

  So `available?/0` asks whether this qpdf can do the **work**, not whether the
  file exists: `qpdf --help=--remove-info` exits 0 for a flag it knows and 2
  for one it does not. Probing with `System.find_executable/1` alone — which is
  what `Vutuv.Uploads.PdfGate` can afford, its poppler tools having had their
  flags for a decade — left the switch **visible and inert** on every one of
  those boxes: the member ticked "remove the metadata", the run died with
  `unrecognized argument --remove-info`, and the file was served with the
  author's name still in it. Our own CI found that before a member did.

  A capability, not a feature: there is no product flag to turn it off, and an
  installation whose qpdf is too old is treated exactly like one with no qpdf
  at all.

  ## Without qpdf, or with one too old

  `available?/0` is probed once per VM and cached, the `:persistent_term`
  pattern `Vutuv.Videos.FFmpeg` established. Nothing is stripped, nothing
  fails, and the composer hides the switch rather than offering an answer this
  installation cannot honour. `QPDF_PATH` names the binary when it is not on
  `$PATH`.
  """

  require Logger

  alias Vutuv.AttachmentStore

  # qpdf exits 0 on success and **3** when it wrote the output but had warnings
  # about the input (a recovered stream length, a broken xref it repaired).
  # A file poppler already accepted and qpdf could rewrite is a cleaned file;
  # treating 3 as failure would leave the metadata on every slightly untidy PDF.
  @written_exit_codes [0, 3]

  # The two flags that do the actual removing, and the two that are not old
  # enough to be assumed. `--help=<flag>` is qpdf's own way of being asked
  # whether it knows one: exit 0 if it does, 2 if it does not.
  @required_flags ["--remove-info", "--remove-metadata"]

  @doc """
  Whether this machine has a qpdf that can do the work (probed once per VM):
  the binary is there **and** it knows the flags that remove the metadata. See
  the moduledoc for why the second half is not optional.
  """
  def available? do
    case :persistent_term.get({__MODULE__, :available}, :unknown) do
      :unknown ->
        verdict = capable?(qpdf())
        :persistent_term.put({__MODULE__, :available}, verdict)
        verdict

      verdict ->
        verdict
    end
  end

  @doc "Drops the cached probe. For tests that point `QPDF_PATH` somewhere else."
  def forget_capability, do: :persistent_term.erase({__MODULE__, :available})

  @doc """
  Rewrites the served copy of `token` without its metadata, deriving it from
  the verbatim original. Answers the moment it was done, or `nil` when nothing
  was done — not a PDF, no qpdf on this box, or qpdf could not read the file.
  A failure is never fatal: the member keeps a publishable file that simply
  still carries its metadata, and the NULL column says so.
  """
  def strip(token, :pdf) do
    with true <- available?(),
         source when is_binary(source) <- AttachmentStore.original_path(token),
         :ok <- run(source, token) do
      DateTime.utc_now(:second)
    else
      _nothing_done -> nil
    end
  end

  def strip(_token, _not_a_pdf), do: nil

  @doc """
  Puts the verbatim upload back on the served copy — what the author asking to
  keep the metadata costs. `:ok` either way; a file whose original is gone
  (swept, or never stored) keeps whatever it has.
  """
  def restore(token) do
    case AttachmentStore.original_path(token) do
      nil -> :ok
      source -> AttachmentStore.replace_served(token, source)
    end
  end

  # qpdf writes a whole new file, so it writes it straight where it is wanted —
  # a scratch name **in the served copy's own directory**, renamed onto the
  # target on success. Two things follow. It is never written beside the
  # *input*, which lives in `originals/`, whose whole promise is that it holds
  # what the member sent and nothing else (and whose own `original*` glob would
  # have matched the leftover); and the commit is a rename rather than a copy,
  # which for a 20 MB PDF is the difference between free and reading and
  # writing it a third time. `after` removes the scratch on every path, so an
  # exception mid-run leaks nothing.
  #
  # The run itself is the shape `Vutuv.Uploads.PdfGate` runs poppler with: no
  # shell, a bounded argument list, and a crash or a non-zero exit caught here
  # rather than taking the caller down. Every path comes from the store, never
  # from a member.
  defp run(source, token) do
    scratch = AttachmentStore.scratch_path(token)

    args = [
      "--remove-info",
      "--remove-metadata",
      "--deterministic-id",
      "--linearize",
      source,
      scratch
    ]

    try do
      case System.cmd(qpdf(), args, stderr_to_stdout: true) do
        {_out, code} when code in @written_exit_codes ->
          AttachmentStore.commit_scratch(token, scratch)

        {out, code} ->
          Logger.warning(
            "qpdf could not clean a file (exit #{code}): #{String.slice(out, 0, 200)}"
          )

          :error
      end
    rescue
      exception ->
        Logger.warning("qpdf run failed: #{Exception.message(exception)}")
        :error
    catch
      :exit, reason ->
        Logger.warning("qpdf run exited: #{inspect(reason)}")
        :error
    after
      File.rm(scratch)
    end
  end

  # Deliberately more than `Vutuv.Uploads.PdfGate.available?/0`'s
  # `find_executable/1`: a qpdf that exists is not a qpdf that can do this, and
  # the two Debian and Ubuntu releases most installations run ship exactly that
  # combination. Fails closed on anything unexpected — a probe that cannot
  # answer is not a probe that said yes.
  defp capable?(binary) do
    case System.find_executable(binary) do
      nil -> false
      path -> Enum.all?(@required_flags, &knows_flag?(path, &1))
    end
  end

  defp knows_flag?(path, flag) do
    case System.cmd(path, ["--help=#{flag}"], stderr_to_stdout: true) do
      {_out, 0} -> true
      _unknown_flag -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # `fetch_env!` like every sibling in this namespace (`Vutuv.Attachments`,
  # `Vutuv.Attachments.PageRender`): a missing `:attachments` block is a broken
  # installation and should say so, not read as "this box has no qpdf" and
  # silently serve every PDF with its author's name still in it.
  defp qpdf, do: Keyword.get(Application.fetch_env!(:vutuv, :attachments), :qpdf, "qpdf")
end

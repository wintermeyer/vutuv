defmodule Vutuv.Images.Backfill do
  @moduledoc """
  Brings every profile picture and cover that existed before the shared
  `images` table into it — the **contract** half of issue #2013, in the same
  expand/contract shape the fingerprint migration used
  (`Vutuv.Uploads.Regenerator` expand, `Vutuv.Uploads.LegacySweeper` contract).

  It **moves no file and changes no URL.** The four member-row columns stay the
  source of truth every URL builder and every display gate reads; this only
  copies what they say into a row and points the member row at it, so the
  previous release keeps serving unchanged through the whole deploy window.

  ## Reconcile, not insert-where-missing

  A row can already exist *and disagree* with the member columns. Until the
  transaction in `Vutuv.Accounts.store_pending_image/6` was added, an upload
  wrote the image row first and the member row second, so a failure in between
  (a pool timeout, a slot dying in the blue/green switch, a `StaleEntryError`)
  left the row naming the new picture and the member row still naming the old
  one. A backfill that only creates rows where none exists skips exactly those
  members, and the contract deploy that drops the columns then destroys the
  only record of which file is really current. So every member is compared
  field by field and a row that disagrees is corrected — `run/1` reports the
  rows it created and the rows it corrected apart.

  A row whose member has no picture of that kind any more is deleted: "there is
  a row" and "there is a picture" are the same statement (the same reason
  `Vutuv.Images.forget_profile_image/2` deletes rather than blanks).

  `classify/3` is what decides which of those a member is, and `run/1` and
  `check/1` both go through it — otherwise the gate would be answering a
  slightly different question from the repair it gates.

  ## Interrupted halfway

  Nothing here is a queue and nothing holds state in memory. Work is a keyset
  scan over `users.id` with **one transaction per member**, and each member's
  outcome depends only on that member's own columns — so a run killed
  mid-flight (a deploy stopping the slot, `Ctrl-C`) leaves every member it
  reached already correct and every member it did not reach exactly as before.
  **Simply run it again**: the members already done cost no write and report
  `unchanged`. `from: "<user id>"` picks up where a log line left off when
  re-reading the whole table is not wanted, and `check/1` — which reads no
  state the run holds — is what says whether anything is still outstanding.

  Per member rather than per batch on purpose: one bad row then fails alone and
  the run carries on. It is a one-shot job over the pictures an installation
  has (1,747 on vutuv.de), so the writes are not batched and no index is added
  for it; the reads are `@batch` members at a time.

  ## The check before the cut

  `check/1` counts every member picture against its row *and* against its file
  on disk, and answers `ok?: false` with a bounded sample of the member ids
  behind each class of mismatch. That is the gate on the deploy that drops the
  columns: run it, read it, and only cut when it is green.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Images
  alias Vutuv.Images.Image
  alias Vutuv.Repo
  alias Vutuv.Uploads

  # Members per SELECT. Small enough that an interrupted run has wasted little,
  # large enough that 1,700 avatars are four reads rather than 1,700.
  @batch 500

  # Ids kept per mismatch class. Before the backfill has run, `missing_row` is
  # every picture on the installation by construction, and `check_image_rows/1`
  # returns its answer straight to a `bin/vutuv eval` console — the count is
  # what the operator needs, a sample is what makes it actionable.
  @sample 100

  # The four the member row holds and the row copies. `:crop` and `:moderation`
  # are legitimately nil on old rows, so a comparison has to be on equality,
  # never on presence.
  @copied [:file, :fingerprint, :crop, :moderation]

  @classes [:missing_row, :mismatched_row, :missing_pointer, :missing_file, :orphan_row]

  @doc "The profile-image kinds this backfill covers."
  def kinds, do: Images.member_columns() |> Map.keys() |> Enum.sort()

  @doc """
  Reconciles every member's picture with its row.

  Options: `only: "avatar" | "cover"`, `dry_run: true` (report, write nothing),
  `from: "<user id>"` (resume the keyset scan above that id).

  Returns `%{"avatar" => %{pictures: n, created: n, corrected: n, unchanged: n,
  dropped: n, failed: n}, "cover" => …}`.
  """
  def run(opts \\ []) do
    for kind <- selected_kinds(opts), into: %{}, do: {kind, run_kind(kind, opts)}
  end

  @doc """
  Counts every member picture against its row and its file on disk, without
  writing anything. Same `only:` option as `run/1`.

  Returns `%{kinds: %{"avatar" => …}, ok?: boolean}`, where each kind carries a
  `%{count: n, sample: [user id]}` per class of mismatch:

    * `missing_row` — a picture with no row at all (the backfill has not run)
    * `mismatched_row` — a row that disagrees with the member's own columns
    * `missing_pointer` — a row the member row does not point at
    * `orphan_row` — a row whose member has no picture of that kind any more
      (sampled by row id, not member id)
    * `missing_file` — the file the member row names is not on disk (in the
      quarantine tree while the picture is `"pending"`, in the served tree
      otherwise). The backfill cannot repair this one — it predates the table
      and the bytes are simply gone — but the cut must not happen with it
      unread.

  It **prints what it found** on the way out, through the same log as `run/1`.
  Both operator paths (`mix vutuv.images.backfill --check` and `bin/vutuv eval
  "Vutuv.Release.check_image_rows()"`) then say the same thing without either
  of them owning a copy of the formatting — the first version put that half in
  the mix task alone, where it went out of step with this map's shape and
  crashed on every call while the release path printed nothing at all.
  """
  def check(opts \\ []) do
    kinds = for kind <- selected_kinds(opts), into: %{}, do: {kind, check_kind(kind)}

    %{kinds: kinds, ok?: Enum.all?(kinds, fn {_kind, result} -> result.ok? end)}
    |> tap(&report/1)
  end

  # The classes in the order an operator wants to read them, with the words
  # that say what each one means.
  @labels [
    missing_row: "without a row",
    mismatched_row: "disagreeing with the member row",
    missing_pointer: "not pointed at",
    missing_file: "with no file on disk",
    orphan_row: "orphan row(s)"
  ]

  defp report(%{kinds: kinds, ok?: ok?}) do
    for {kind, result} <- kinds do
      log(
        "#{kind}: #{result.pictures} picture(s), #{result.rows} row(s) — " <>
          Enum.map_join(@labels, ", ", fn {class, label} ->
            "#{Map.fetch!(result, class).count} #{label}"
          end)
      )

      for {class, label} <- @labels, Map.fetch!(result, class).count > 0 do
        log("  #{label}: #{sample_line(Map.fetch!(result, class))}")
      end
    end

    log(
      if ok?,
        do: "Every member picture has its row and its file. Safe to cut.",
        else: "MISMATCH — do not drop the member row's image columns yet."
    )
  end

  # The count above is the number that matters; a handful of ids is what makes
  # it actionable, and printing 1,700 of them buries the count.
  defp sample_line(%{count: count, sample: sample}) do
    shown = Enum.take(sample, 10)
    Enum.join(shown, " ") <> if(count > length(shown), do: " … (#{count} total)", else: "")
  end

  defp selected_kinds(opts) do
    case Keyword.get(opts, :only) do
      nil -> kinds()
      kind -> [kind]
    end
  end

  ## What is wrong with this member, if anything

  # The one place that decides. `run/1` repairs what this names and `check/1`
  # reports it, so a class added here can never be invisible to the gate.
  defp classify(user, row, cols) do
    cond do
      is_nil(row) -> :missing_row
      drifted?(row, desired(user, cols)) -> :mismatched_row
      Map.get(user, cols.pointer) != row.id -> :missing_pointer
      true -> :ok
    end
  end

  defp desired(user, cols),
    do: Map.new(@copied, fn field -> {field, Map.get(user, cols[field])} end)

  defp drifted?(row, desired), do: Enum.any?(desired, fn {f, v} -> Map.get(row, f) != v end)

  ## Reconcile

  defp run_kind(kind, opts) do
    cols = Images.member_columns(kind)
    tally = %{pictures: 0, created: 0, corrected: 0, unchanged: 0, dropped: 0, failed: 0}

    log("#{kind}: reconciling#{if opts[:dry_run], do: " — dry run", else: ""}")

    # One line per batch, so an interrupted run leaves the operator an id to
    # resume from. Per batch, not per member: 1,700 lines is not progress.
    on_batch = fn id -> log("  #{kind}: through #{id} (--from to resume here)") end

    tally
    |> each_batch(
      kind,
      cols,
      Keyword.get(opts, :from),
      fn {user, row}, acc ->
        acc
        |> bump(:pictures)
        |> bump(repair(classify(user, row, cols), user, row, kind, cols, opts))
      end,
      on_batch
    )
    |> drop_orphans(kind, cols, opts)
    |> tap(fn t ->
      log(
        "#{kind}: #{t.pictures} picture(s) — #{t.created} row(s) created, " <>
          "#{t.corrected} corrected, #{t.unchanged} already right, " <>
          "#{t.dropped} orphan row(s) dropped, #{t.failed} failed"
      )
    end)
  end

  # The keyset walk both halves share. One SELECT per batch carries the member
  # and its row together, so a member that is already right costs no second
  # statement.
  defp each_batch(acc, kind, cols, cursor, fun, on_batch \\ fn _id -> :ok end) do
    case Repo.all(batch_query(kind, cols, cursor)) do
      [] ->
        acc

      rows ->
        acc = Enum.reduce(rows, acc, fun)
        {last_user, _row} = List.last(rows)
        on_batch.(last_user.id)
        each_batch(acc, kind, cols, last_user.id, fun, on_batch)
    end
  end

  defp batch_query(kind, cols, cursor) do
    query =
      from(u in User,
        left_join: i in Image,
        on: i.user_id == u.id and i.kind == ^kind,
        where: not is_nil(field(u, ^cols.file)),
        order_by: [asc: u.id],
        limit: @batch,
        select: {u, i}
      )

    if cursor, do: where(query, [u], u.id > ^cursor), else: query
  end

  defp repair(:ok, _user, _row, _kind, _cols, _opts), do: :unchanged

  defp repair(verdict, user, row, kind, cols, opts) do
    outcome = if verdict == :missing_row, do: :created, else: :corrected

    if opts[:dry_run],
      do: outcome,
      else: write(user, cols, outcome, fn -> mend(verdict, user, row, kind, cols) end)
  end

  # A create goes through `Images.put_profile_image/3`, the same function the
  # upload path uses: it mints the fresh token and carries the upsert against
  # the partial unique index, so a row an upload writes between this batch's
  # SELECT and this write converges instead of failing.
  defp mend(:missing_row, user, _row, kind, cols) do
    with {:ok, image} <- Images.put_profile_image(user, kind, desired(user, cols)),
         do: point_at(user, cols, image.id)
  end

  # The row is overwritten from the member columns, never the other way round:
  # they are what every URL and every display gate reads today, so they are the
  # truth this table has to agree with. Not `put_profile_image/3`, which always
  # mints a fresh token — here a **fresh token goes with a changed picture**
  # only, because a token names the bytes: a row corrected back to a different
  # file must not keep a handle that named the other one, and a row whose
  # moderation state alone drifted must not lose the handle it has.
  defp mend(:mismatched_row, user, row, _kind, cols) do
    desired = desired(user, cols)

    with {:ok, image} <-
           row
           |> Image.changeset(desired)
           |> remint_token(row, desired)
           |> Repo.update(),
         do: point_at(user, cols, image.id)
  end

  # The row is right and only the member row's pointer is not — the shape a
  # half-committed upload leaves behind.
  defp mend(:missing_pointer, user, row, _kind, cols), do: point_at(user, cols, row.id)

  # `token` is set programmatically, never cast, so the fresh one is put on the
  # changeset here rather than smuggled in through the attrs.
  defp remint_token(changeset, row, desired) do
    if row.fingerprint == desired.fingerprint and row.file == desired.file,
      do: changeset,
      else: Ecto.Changeset.put_change(changeset, :token, Uploads.gen_token())
  end

  defp point_at(user, cols, image_id) do
    from(u in User, where: u.id == ^user.id)
    |> Repo.update_all(set: [{cols.pointer, image_id}])

    :ok
  end

  # Row and pointer move together or not at all, so an interrupted run can
  # never leave the pair the upload path used to be able to leave. A member the
  # database refuses is logged and counted, never fatal to the run.
  defp write(user, cols, outcome, fun) do
    result =
      Repo.transaction(fn ->
        case fun.() do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} ->
        outcome

      {:error, reason} ->
        log("  FAIL #{cols.file} #{user.id}: #{inspect(reason)}")
        :failed
    end
  rescue
    exception ->
      log("  FAIL #{cols.file} #{user.id}: #{inspect(exception)}")
      :failed
  end

  # A row whose member has no picture of that kind any more, deleted in one
  # statement (`Vutuv.Images.forget_profile_image/2` is its single-row twin on
  # the moderation path). The member row's pointer follows by itself
  # (`on_delete: :nilify_all`).
  defp drop_orphans(tally, kind, cols, opts) do
    dropped =
      if opts[:dry_run] do
        Repo.aggregate(orphan_query(kind, cols), :count)
      else
        {count, _} = Repo.delete_all(orphan_query(kind, cols))
        count
      end

    %{tally | dropped: tally.dropped + dropped}
  end

  # Deletable as it stands: `delete_all` takes a join-free query, so the "has
  # this member still got a picture" half is a correlated subquery.
  defp orphan_query(kind, cols) do
    ownerless =
      from(u in User,
        where: u.id == parent_as(:image).user_id and is_nil(field(u, ^cols.file))
      )

    # A frozen picture is *meant* to have empty member columns — that is how a
    # copyright freeze hides it (#2012) — and the row is the only record of
    # what the case is about and what an unfreeze has to write back. So it is
    # not an orphan, here or in the check's count.
    from(i in Image,
      as: :image,
      where: i.kind == ^kind and is_nil(i.frozen_at) and exists(subquery(ownerless))
    )
  end

  ## Check

  defp check_kind(kind) do
    cols = Images.member_columns(kind)

    empty = %{
      pictures: 0,
      rows: Repo.aggregate(from(i in Image, where: i.kind == ^kind), :count),
      missing_row: blank(),
      mismatched_row: blank(),
      missing_pointer: blank(),
      missing_file: blank(),
      orphan_row: orphan_class(kind, cols)
    }

    empty
    |> each_batch(kind, cols, nil, fn {user, row}, acc ->
      acc
      |> Map.update!(:pictures, &(&1 + 1))
      |> flag(classify(user, row, cols), user.id)
      |> flag(file_verdict(user, kind), user.id)
    end)
    |> finish_check()
  end

  defp file_verdict(user, kind) do
    if is_nil(Images.stored_path(user, kind)), do: :missing_file, else: :ok
  end

  defp blank, do: %{count: 0, sample: []}

  defp orphan_class(kind, cols) do
    query = orphan_query(kind, cols)

    %{
      count: Repo.aggregate(query, :count),
      sample: Repo.all(from(i in query, order_by: [asc: i.id], limit: @sample, select: i.id))
    }
  end

  defp flag(result, :ok, _id), do: result

  defp flag(result, class, id) do
    Map.update!(result, class, fn %{count: count, sample: sample} ->
      %{count: count + 1, sample: if(count < @sample, do: sample ++ [id], else: sample)}
    end)
  end

  defp finish_check(result),
    do: Map.put(result, :ok?, Enum.all?(@classes, &(Map.fetch!(result, &1).count == 0)))

  ## Shared

  defp bump(tally, key), do: Map.update!(tally, key, &(&1 + 1))

  # The quiet-flag logic lives once in Vutuv.Uploads.log/1.
  defp log(message), do: Uploads.log(message)
end

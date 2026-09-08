defmodule Vutuv.Images.Backfill do
  @moduledoc """
  Brings every picture that existed before the shared `images` table into it —
  the **contract** half of issue #2013 for a profile picture and cover, and of
  #2015 for the kinds that still keep a table of their own — in the same
  expand/contract shape the fingerprint migration used
  (`Vutuv.Uploads.Regenerator` expand, `Vutuv.Uploads.LegacySweeper` contract).

  It **moves no file and changes no URL.** Whatever a picture already lives in
  stays the source of truth every URL builder and every display gate reads —
  columns on a parent row for a profile picture and a review cover, its own
  gallery row for the rest — and this only copies what that says into a row, so
  the previous release keeps serving unchanged through the whole deploy window.

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
  `Vutuv.Images.discard_profile_image/3` deletes rather than blanks).

  `classify/3` is what decides which of those a picture is, and `run/1` and
  `check/1` both go through it — otherwise the gate would be answering a
  slightly different question from the repair it gates.

  ## Interrupted halfway

  Nothing here is a queue and nothing holds state in memory. Work is a keyset
  scan over the source table's `id` with **one transaction per picture**, and
  each picture's outcome depends only on its own columns — so a run killed
  mid-flight (a deploy stopping the slot, `Ctrl-C`) leaves every picture it
  reached already correct and every picture it did not reach exactly as before.
  **Simply run it again**: the ones already done cost no write and report
  `unchanged`. `from: "<id>"` picks up where a log line left off when
  re-reading the whole table is not wanted, and `check/1` — which reads no
  state the run holds — is what says whether anything is still outstanding.

  Per picture rather than per batch on purpose: one bad row then fails alone
  and the run carries on. It is a one-shot job over the pictures an
  installation has (1,747 on vutuv.de), so the writes are not batched and no
  index is added for it; the reads are `@batch` at a time.

  ## The check before the cut

  `check/1` counts every picture against its row *and* against its file on
  disk, and answers `ok?: false` with a bounded sample of the ids behind each
  class of mismatch. That is the gate on the deploy that drops the columns (or
  retires a gallery kind's table): run it, read it, and only cut when it is
  green.

  ## Two shapes, one machine (issue #2015)

  `source/1` is the only per-kind thing here, and it has two shapes:

    * `%{cols: …}` — the truth is columns on a **parent row**, joined by the
      `images` column naming that parent. A member's avatar and cover, and
      since #2055 a review's cover, which is this shape and not the other one.
      Read whole from `Vutuv.Images.column_source/1`.
    * `%{gallery: …}` — the truth is a **row of the picture's own**, joined by
      the `token` both sides carry. A job-posting picture since #2054, a post
      photo since #2052 and an organization image since #2053. Read whole from
      `Vutuv.Images.mirror_source/1`.

  Everything around them is shared: the keyset walk, the class vocabulary, the
  repair, the sample, the printing and both operator commands. `missing_pointer`
  is the one class a source has to earn — only a parent that keeps a pointer
  back at the row can lose one — so the report never prints a zero for a class
  that kind cannot have.

  **A kind adds no per-kind branch here.** Both registries carry what this pass
  needs: which columns are copied, the schema, the store, and (for a parent
  with no pointer) the function that repairs one row. So a kind cannot be
  written on the request path and be invisible to this pass, and no clause here
  matches a schema module. #2052 added not a line; #2053 changed one, shared
  rather than per-kind — an organization image is the first source with a
  column spelled differently on the two sides, so the desired values come from
  `Vutuv.Images.mirror_attrs/2`, the same function the mirror writes through,
  rather than a `Map.take/2` on the source row, which would have skipped that
  column in silence. #2055 gave the column shape the same treatment:
  `Vutuv.Images.column_attrs/2` is the twin, so the write and the comparison
  read one list there too.
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

  # What a picture of any shape can be wrong in. `missing_pointer` is the one
  # class that is not universal: it belongs to a parent that keeps a pointer
  # back at the row — a member row does (`users.avatar_image_id`, #2013), a
  # review row and a gallery row do not — so `source/1` appends it per source
  # rather than a second list repeating these four.
  @classes [:missing_row, :mismatched_row, :missing_file, :orphan_row]

  @doc """
  The image kinds this backfill covers: the profile kinds, plus the kinds whose
  own table is still the truth (`Vutuv.Images.mirrored_kinds/0`).

  Derived, never listed here. A second per-kind list would let a kind be
  mirrored on the request path and invisible to this one, and the failure is
  the worst shape there is: the check would print *"Every picture has its row
  and its file. Safe to cut."* for a kind it never looked at.
  """
  def kinds, do: Enum.sort(Images.column_kinds() ++ Images.mirrored_kinds())

  @doc """
  Reconciles every picture with its row.

  Options: `only: "<kind>"` (one of `kinds/0`), `dry_run: true` (report, write
  nothing), `from: "<id>"` (resume the keyset scan above that id — a member id
  for a profile kind, a gallery row id for the rest).

  Returns `%{"avatar" => %{pictures: n, created: n, corrected: n, unchanged: n,
  dropped: n, failed: n}, "cover" => …}`, one entry per kind.
  """
  def run(opts \\ []) do
    for kind <- selected_kinds(opts), into: %{}, do: {kind, run_kind(kind, opts)}
  end

  @doc """
  Counts every picture against its row and its file on disk, without writing
  anything. Same `only:` option as `run/1`.

  Returns `%{kinds: %{"avatar" => …}, ok?: boolean}`, where each kind carries a
  `%{count: n, sample: [id]}` per class of mismatch it can have — a class the
  kind cannot have is simply not a key:

    * `missing_row` — a picture with no row at all (the backfill has not run)
    * `mismatched_row` — a row that disagrees with the picture's own columns
    * `missing_pointer` — a row the member row does not point at (profile
      kinds only; a gallery picture is joined on its token and has no pointer)
    * `orphan_row` — a row whose picture is gone (sampled by row id)
    * `missing_file` — the file the row names is not on disk (in the quarantine
      tree while a profile picture is `"pending"`, in the served tree
      otherwise; a gallery picture's proxy serves straight out of its token
      directory). The backfill cannot repair this one — the bytes are simply
      gone — but the cut must not happen with it unread.

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
    mismatched_row: "disagreeing with the source row",
    missing_pointer: "not pointed at",
    missing_file: "with no file on disk",
    orphan_row: "orphan row(s)"
  ]

  defp report(%{kinds: kinds, ok?: ok?}) do
    for {kind, result} <- kinds do
      # A result carries a key only for the classes its kind can have, which is
      # what decides the line this prints.
      labels = Enum.filter(@labels, fn {class, _label} -> Map.has_key?(result, class) end)

      log(
        "#{kind}: #{result.pictures} picture(s), #{result.rows} row(s) — " <>
          Enum.map_join(labels, ", ", fn {class, label} ->
            "#{Map.fetch!(result, class).count} #{label}"
          end)
      )

      for {class, label} <- labels, Map.fetch!(result, class).count > 0 do
        log("  #{label}: #{sample_line(Map.fetch!(result, class))}")
      end
    end

    log(
      if ok?,
        do: "Every picture has its row and its file. Safe to cut.",
        else: "MISMATCH — do not retire the old image columns or tables yet."
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

  ## The source a kind is reconciled from

  # One map per kind, naming where the pictures are and which classes that kind
  # can report. Everything below dispatches on its shape — `%{cols: …}` for a
  # profile picture whose truth is four member-row columns, `%{gallery: …}` for
  # a picture whose truth is a row in a table of its own — and nothing below is
  # written twice.
  defp source(kind) do
    if Images.mirrored?(kind) do
      %{kind: kind, classes: @classes, gallery: Images.mirror_source(kind)}
    else
      cols = Images.column_source(kind)

      %{kind: kind, classes: @classes ++ pointer_class(cols), cols: cols}
    end
  end

  defp pointer_class(%{pointer: _}), do: [:missing_pointer]
  defp pointer_class(_cols), do: []

  ## What is wrong with this picture, if anything

  # The one place that decides. `run/1` repairs what this names and `check/1`
  # reports it, so a class added here can never be invisible to the gate.
  defp classify(%{kind: kind, cols: cols}, parent, row) do
    cond do
      is_nil(row) -> :missing_row
      drifted?(row, Images.column_attrs(kind, parent)) -> :mismatched_row
      pointer_lost?(cols, parent, row) -> :missing_pointer
      true -> :ok
    end
  end

  # No pointer to lose: the token both rows carry is the join key, and the row
  # was found by it.
  #
  # The desired values come from `Vutuv.Images.mirror_attrs/2`, the same
  # function the mirror writes through, rather than a `Map.take/2` on the source
  # row: one column is spelled differently on the two sides
  # (`organization_images.user_id` is `images.uploader_user_id`), and `Map.take`
  # would silently drop it — so a drifted uploader would read as "already
  # right" here and be repaired by nothing.
  defp classify(%{kind: kind, gallery: _gallery}, gallery_row, row) do
    cond do
      is_nil(row) -> :missing_row
      drifted?(row, desired_mirror(kind, gallery_row)) -> :mismatched_row
      true -> :ok
    end
  end

  # Only a parent that keeps a pointer can lose one. A review row has none:
  # `images.post_review_id` is the join key itself, so a row that was found is
  # a row that is pointed at.
  defp pointer_lost?(%{pointer: pointer}, parent, row), do: Map.get(parent, pointer) != row.id
  defp pointer_lost?(_cols, _parent, _row), do: false

  # `token` is the join key, so it is equal by construction and comparing it
  # would only ever say "no".
  defp desired_mirror(kind, gallery_row),
    do: kind |> Images.mirror_attrs(gallery_row) |> Map.delete(:token)

  defp drifted?(row, desired), do: Enum.any?(desired, fn {f, v} -> Map.get(row, f) != v end)

  ## Reconcile

  defp run_kind(kind, opts) do
    source = source(kind)
    tally = %{pictures: 0, created: 0, corrected: 0, unchanged: 0, dropped: 0, failed: 0}

    log("#{kind}: reconciling#{if opts[:dry_run], do: " — dry run", else: ""}")

    # One line per batch, so an interrupted run leaves the operator an id to
    # resume from. Per batch, not per member: 1,700 lines is not progress.
    on_batch = fn id -> log("  #{kind}: through #{id} (--from to resume here)") end

    tally
    |> each_batch(
      source,
      Keyword.get(opts, :from),
      fn {picture, row}, acc ->
        acc
        |> bump(:pictures)
        |> bump(repair(source, classify(source, picture, row), picture, row, opts))
      end,
      on_batch
    )
    |> drop_orphans(source, opts)
    |> tap(fn t ->
      log(
        "#{kind}: #{t.pictures} picture(s) — #{t.created} row(s) created, " <>
          "#{t.corrected} corrected, #{t.unchanged} already right, " <>
          "#{t.dropped} orphan row(s) dropped, #{t.failed} failed"
      )
    end)
  end

  # The keyset walk every kind and both halves share. One SELECT per batch
  # carries the picture and its row together, so a picture that is already
  # right costs no second statement.
  defp each_batch(acc, source, cursor, fun, on_batch \\ fn _id -> :ok end) do
    case Repo.all(batch_query(source, cursor)) do
      [] ->
        acc

      rows ->
        acc = Enum.reduce(rows, acc, fun)
        {last, _row} = List.last(rows)
        on_batch.(last.id)
        each_batch(acc, source, last.id, fun, on_batch)
    end
  end

  # The parent is a member row for a profile picture and a review row for a
  # review cover, and the join is the `images` column naming it — the same
  # shape either way, which is what `Vutuv.Images.column_source/1` is for.
  defp batch_query(%{kind: kind, cols: cols}, cursor) do
    query =
      from(p in cols.schema,
        left_join: i in Image,
        on: field(i, ^cols.owner) == p.id and i.kind == ^kind,
        where: not is_nil(field(p, ^cols.copied.file)),
        order_by: [asc: p.id],
        limit: @batch,
        select: {p, i}
      )

    if cursor, do: where(query, [p], p.id > ^cursor), else: query
  end

  # The join is on the token, which is unique in both tables — so this is the
  # same one-SELECT-per-batch shape, and the gallery row it carries is exactly
  # what `Vutuv.Images.mirror/2` takes.
  defp batch_query(%{kind: kind, gallery: gallery}, cursor) do
    query =
      from(g in gallery.schema,
        left_join: i in Image,
        on: i.token == g.token and i.kind == ^kind,
        order_by: [asc: g.id],
        limit: @batch,
        select: {g, i}
      )

    if cursor, do: where(query, [g], g.id > ^cursor), else: query
  end

  defp repair(_source, :ok, _picture, _row, _opts), do: :unchanged

  defp repair(source, verdict, picture, row, opts) do
    outcome = if verdict == :missing_row, do: :created, else: :corrected

    if opts[:dry_run],
      do: outcome,
      else: write(source, picture, outcome, fn -> mend(source, verdict, picture, row) end)
  end

  # A create goes through `Images.put_profile_image/3`, the same function the
  # upload path uses: it mints the fresh token and carries the upsert against
  # the partial unique index, so a row an upload writes between this batch's
  # SELECT and this write converges instead of failing.
  # A parent that carries its own repair has one for both verdicts, and it is
  # the same statement the request path writes: for a review cover that is
  # `Vutuv.Images.sync_review_cover/1`, which upserts on `post_review_id` and
  # re-mints the token only when the bytes it names changed — the same rule
  # `remint_token/3` states below, decided in SQL because two fetches can reach
  # it at once. Read off the source rather than matched on the parent schema,
  # so a second such kind is a registry entry rather than another clause here.
  defp mend(%{cols: %{sync: {module, fun}}}, verdict, parent, _row)
       when verdict in [:missing_row, :mismatched_row] do
    apply(module, fun, [parent])
  end

  defp mend(%{kind: kind, cols: %{pointer: _} = cols}, :missing_row, user, _row) do
    with {:ok, image} <- Images.put_profile_image(user, kind, Images.column_attrs(kind, user)),
         do: point_at(user, cols, image.id)
  end

  # The row is overwritten from the member columns, never the other way round:
  # they are what every URL and every display gate reads today, so they are the
  # truth this table has to agree with. Not `put_profile_image/3`, which always
  # mints a fresh token — here a **fresh token goes with a changed picture**
  # only, because a token names the bytes: a row corrected back to a different
  # file must not keep a handle that named the other one, and a row whose
  # moderation state alone drifted must not lose the handle it has.
  defp mend(%{kind: kind, cols: %{pointer: _} = cols}, :mismatched_row, user, row) do
    desired = Images.column_attrs(kind, user)

    with {:ok, image} <-
           row
           |> Image.changeset(desired)
           |> remint_token(row, desired)
           |> Repo.update(),
         do: point_at(user, cols, image.id)
  end

  # The row is right and only the member row's pointer is not — the shape a
  # half-committed upload leaves behind.
  defp mend(%{cols: %{pointer: _} = cols}, :missing_pointer, user, row),
    do: point_at(user, cols, row.id)

  # A gallery picture has one repair for both verdicts, and it is the same
  # upsert the request path writes: `Vutuv.Images.mirror/2` keys on the token,
  # so creating the row that was never written and correcting one that drifted
  # are the same statement. The token is never re-minted here — for a gallery
  # picture it is minted once at upload and a re-upload is a different row, so
  # there is no "the bytes changed under the handle" case to answer.
  defp mend(%{kind: kind, gallery: _}, verdict, gallery_row, _row)
       when verdict in [:missing_row, :mismatched_row] do
    Images.mirror(kind, gallery_row)
  end

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

  # A picture the database refuses is logged and counted, never fatal to the
  # run.
  defp write(source, picture, outcome, fun) do
    case attempt(source, fun) do
      :ok -> outcome
      {:error, reason} -> failed(source, picture, reason)
    end
  rescue
    exception -> failed(source, picture, exception)
  end

  # A profile repair writes the row **and** the member row's pointer, so the two
  # move together or not at all — that half-committed pair is the very thing
  # this backfill exists to mend. Everything else (a gallery mirror, a review
  # cover) is one idempotent upsert, and a transaction around it would be a
  # BEGIN and a COMMIT buying nothing — so the pointer is what decides, not the
  # shape.
  defp attempt(%{cols: %{pointer: _}}, fun) do
    case Repo.transaction(fn -> or_rollback(fun.()) end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt(_source, fun), do: fun.()

  defp or_rollback(:ok), do: :ok
  defp or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp failed(source, picture, reason) do
    log("  FAIL #{source.kind} #{picture.id}: #{inspect(reason)}")
    :failed
  end

  # A row whose picture is gone, deleted in one statement
  # (`Vutuv.Images.discard_profile_image/3` and `Vutuv.Images.forget/2` are its
  # single-row twins on the request path). A member row's pointer follows by
  # itself (`on_delete: :nilify_all`); a gallery row has no pointer to clear.
  defp drop_orphans(tally, source, opts) do
    dropped =
      if opts[:dry_run] do
        Repo.aggregate(orphan_query(source), :count)
      else
        {count, _} = Repo.delete_all(orphan_query(source))
        count
      end

    %{tally | dropped: tally.dropped + dropped}
  end

  # Deletable as it stands: `delete_all` takes a join-free query, so the "is
  # there still a picture" half is a correlated subquery.
  #
  # A frozen picture is *meant* to look gone from the old side — that is how a
  # copyright freeze hides a profile picture (#2012), by clearing the member
  # row — and the row is the only record of what the case is about and what an
  # unfreeze has to write back. So it is never an orphan, here or in the
  # check's count.
  defp orphan_query(%{kind: kind, cols: cols}) do
    ownerless =
      from(p in cols.schema,
        where:
          p.id == field(parent_as(:image), ^cols.owner) and is_nil(field(p, ^cols.copied.file))
      )

    from(i in Image,
      as: :image,
      where: i.kind == ^kind and is_nil(i.frozen_at) and exists(subquery(ownerless))
    )
  end

  defp orphan_query(%{kind: kind, gallery: gallery}) do
    still_there = from(g in gallery.schema, where: g.token == parent_as(:image).token)

    from(i in Image,
      as: :image,
      where: i.kind == ^kind and is_nil(i.frozen_at) and not exists(subquery(still_there))
    )
  end

  ## Check

  defp check_kind(kind) do
    source = source(kind)

    # Only the classes this kind can have, so `report/1` prints no zero for a
    # class it cannot — a gallery picture has no pointer to lose, and a line
    # saying "0 not pointed at" would invite somebody to go looking for one.
    empty =
      source.classes
      |> Map.new(&{&1, blank()})
      |> Map.merge(%{
        pictures: 0,
        rows: Repo.aggregate(from(i in Image, where: i.kind == ^kind), :count),
        orphan_row: orphan_class(source)
      })

    empty
    |> each_batch(source, nil, fn {picture, row}, acc ->
      acc
      |> Map.update!(:pictures, &(&1 + 1))
      |> flag(classify(source, picture, row), picture.id)
      |> flag(file_verdict(source, picture, row), picture.id)
    end)
    |> finish_check(source)
  end

  # A picture with no row yet is already named as `:missing_row`, and since
  # #2027 the profile path is resolved from that row — so asking here too would
  # report every un-backfilled member twice and call the second reading a
  # missing file.
  defp file_verdict(_source, _picture, nil), do: :ok

  # A column kind with a store of its own answers from the parent row already
  # in hand: a review cover is served through its own proxy off the review's
  # id, and the version segment is the fingerprinted name the `cover` column
  # yields. No quarantine branch — this kind never had one, the proxy is what
  # holds a cover back while the AI gate runs.
  defp file_verdict(%{cols: %{store: store}}, parent, _row),
    do: if(is_nil(store.stored_path(parent)), do: :missing_file, else: :ok)

  defp file_verdict(%{kind: kind, cols: cols}, user, row) do
    # The row is in hand, so hand it over as the preload `member_image/2` would
    # otherwise look up: one query per member over the whole table, for nothing.
    user = Map.put(user, cols.assoc, row)

    if is_nil(Images.stored_path(user, kind)), do: :missing_file, else: :ok
  end

  # A gallery picture is served through its own proxy off its own token, so the
  # store answers straight from the row already in hand. No quarantine branch:
  # these kinds never had one — the proxy is what holds a picture back while
  # the AI gate runs, not a second tree.
  defp file_verdict(%{gallery: gallery}, gallery_row, _row) do
    if is_nil(gallery.store.version_path(gallery_row, gallery.preview)),
      do: :missing_file,
      else: :ok
  end

  defp blank, do: %{count: 0, sample: []}

  defp orphan_class(source) do
    query = orphan_query(source)

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

  defp finish_check(result, source),
    do: Map.put(result, :ok?, Enum.all?(source.classes, &(Map.fetch!(result, &1).count == 0)))

  ## Shared

  defp bump(tally, key), do: Map.update!(tally, key, &(&1 + 1))

  # The quiet-flag logic lives once in Vutuv.Uploads.log/1.
  defp log(message), do: Uploads.log(message)
end

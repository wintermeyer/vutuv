defmodule Vutuv.Images do
  @moduledoc """
  The one table every stored picture ends up in, and the per-kind facts that do
  not belong on a row. The whole story — why the table exists, what is expand
  and what is contract, and what a member row still holds meanwhile — is in
  `docs/architecture/images.md`.

  The invariant this module carries: **this release writes both.** A picture is
  a row here *and* the four columns it has always lived in on the member row,
  which stay the source of truth for every URL and every display gate until
  #2014 has backfilled the older pictures and dropped them.

  `serving/1` is the second thing here that is not a column: how a kind reaches
  a reader decides what its off switch is, and a kind nobody has declared
  raises rather than inheriting one.
  """

  import Ecto.Query, warn: false

  alias Vutuv.Accounts.User
  alias Vutuv.Images.Image
  alias Vutuv.Repo
  alias Vutuv.Uploads

  # The kinds that have a row today. `Vutuv.Moderation.ImageScans` uses the
  # same two strings for its scan kinds, so a scan row and an image row name
  # the same thing. #2015 brings the rest.
  @kinds ~w(avatar cover)

  @doc "The image kinds that live in this table today."
  def kinds, do: @kinds

  @doc """
  How this kind reaches a reader.

    * `:static` — the derived files sit in a public tree nginx serves straight
      off disk, so nothing asks this application for permission and the only
      off switch is moving the bytes out of that tree: the quarantine tree
      while the AI gate has not ruled (`Vutuv.Uploads.quarantine_dir/1`), the
      takedown hold while a copyright case runs
      (`Vutuv.Uploads.hold_dir/1`, `freeze/1` below).
    * `:proxy` — every byte goes through a controller that authorizes the
      reader first, so the row is the off switch.

  Raises for an undeclared kind: a picture that inherits a default is one
  nobody knows how to take offline.
  """
  def serving(kind) when kind in @kinds, do: :static

  def serving(kind),
    do:
      raise(ArgumentError, """
      no serving strategy declared for image kind #{inspect(kind)}. \
      Declare it in Vutuv.Images.serving/1 — a kind that inherits a default \
      is a picture nobody knows how to take offline.\
      """)

  # Which member-row column holds what for a profile picture, plus the uploader
  # that owns its files. The one place these names are written: the backfill
  # (`Vutuv.Images.Backfill`), `Vutuv.Moderation.ImageSubjects` and
  # `Vutuv.Accounts` all read them from here, so the contract deploy that drops
  # the four columns per kind has one list to delete rather than four copies to
  # find.
  @profile_columns %{
    "avatar" => %{
      file: :avatar,
      fingerprint: :avatar_fingerprint,
      crop: :avatar_crop,
      moderation: :avatar_moderation,
      pointer: :avatar_image_id,
      module: Vutuv.Avatar,
      prefix: "avatars",
      # The version a human is shown this kind at — the report form and the two
      # case pages. Per kind here rather than branched at those call sites,
      # which is what `@profile_columns` is for.
      preview: :medium
    },
    "cover" => %{
      file: :cover_photo,
      fingerprint: :cover_fingerprint,
      crop: :cover_crop,
      moderation: :cover_moderation,
      pointer: :cover_image_id,
      module: Vutuv.Cover,
      prefix: "covers",
      preview: :wide
    }
  }

  @doc """
  The member-row columns this kind still lives in, keyed by what each holds
  (`:file`, `:fingerprint`, `:crop`, `:moderation`, `:pointer`), plus the
  `:module` that owns the files, its on-disk `:prefix` and the `:preview`
  version a human is shown it at.
  """
  def member_columns, do: @profile_columns
  def member_columns(kind) when is_map_key(@profile_columns, kind), do: @profile_columns[kind]

  @doc """
  The member-row column pointing at this kind's row. The one place that name is
  written; `Vutuv.Accounts`, `Vutuv.Uploads` and
  `Vutuv.Moderation.ImageSubjects` all read it from here.
  """
  def pointer_field(kind) when is_map_key(@profile_columns, kind),
    do: @profile_columns[kind].pointer

  @doc """
  Where this member's picture of that kind actually is on disk right now, or
  `nil` when the row names a file that is not there.

  Asks the uploader rather than rebuilding a path: an unmoderated picture sits
  in the served tree under whichever of the three naming schemes its row is on
  (fingerprinted, stable-legacy, name-derived), and one still `"pending"` sits
  in the quarantine tree instead. `Vutuv.Images.Backfill.check/1` is what needs
  the distinction — "the row is right" and "the bytes are there" are two
  different questions and the cut before #2012 needs both answered.
  """
  def stored_path(user, kind, version \\ nil)

  def stored_path(%User{} = user, kind, version) when is_map_key(@profile_columns, kind) do
    config = @profile_columns[kind]
    version = version || config.preview

    if Map.get(user, config.moderation) == "pending",
      do: config.module.pending_preview_path(user, version),
      else: config.module.stored_path(user, version)
  end

  @doc """
  Where this picture's bytes are **right now**, wherever that is: the takedown
  hold while a copyright case holds it (`Vutuv.Uploads.hold_dir/1`), otherwise
  the tree its member row points at. `nil` when neither has them.

  The one answer the two case pages need — a frozen picture is out of every
  tree nginx serves, so an admin ruling on a copyright claim can see it only
  through this.
  """
  def bytes_path(%Image{} = image, version \\ nil) do
    config = @profile_columns[image.kind]
    version = version || config.preview

    case Uploads.held_version_path(image.id, version, image.fingerprint) do
      path when is_binary(path) ->
        path

      nil ->
        with %User{} = owner <- owner(image),
             do: stored_path(owner, image.kind, version)
    end
  end

  @doc """
  What a reader is shown for this picture — the same URL the profile renders,
  so a picture already held by another case (or still in the AI gate) shows the
  silhouette here too rather than a URL nothing answers. For the report form.
  """
  def preview_url(%Image{} = image) do
    config = @profile_columns[image.kind]

    with %User{} = owner <- owner(image),
         do: config.module.display_url(owner, config.preview)
  end

  @doc """
  Records the picture a member just uploaded, replacing whatever row that
  member had for this kind.

  Called from `Vutuv.Accounts.store_pending_image/6` once the file is on disk,
  in the same step that fills the member row's own columns. A **fresh token**
  is minted every time, because a token names the bytes: after a re-upload, a
  report that named the old picture should point at nothing rather than quietly
  at the new one.
  """
  def put_profile_image(%User{} = user, kind, attrs) when kind in @kinds do
    if frozen?(user.id, kind) do
      {:error, :frozen}
    else
      %Image{kind: kind, user_id: user.id, token: Uploads.gen_token()}
      |> Image.changeset(attrs)
      # `frozen_at` is deliberately NOT in the replace list: a freeze is a
      # takedown, and a re-upload must not be able to lift one. The guard above
      # is the readable half of the same rule — this list is what would quietly
      # undo it if somebody added the column to it.
      |> Repo.insert(
        on_conflict: {:replace, [:token, :file, :fingerprint, :crop, :moderation, :updated_at]},
        conflict_target: {:unsafe_fragment, "(user_id, kind) WHERE kind IN ('avatar', 'cover')"},
        returning: [:id]
      )
    end
  end

  @doc """
  Whether this member's picture of that kind is held by a copyright freeze.

  Asked at three layers on purpose, and each one is load-bearing:
  `VutuvWeb.UserController.update/2` asks before the write so the form can say
  *why* it refused rather than dropping the upload silently,
  `Vutuv.Accounts.store_pending_image/6` asks before `store/3` writes a byte,
  and `put_profile_image/3` refuses the row itself — the row's four columns are
  what `unfreeze/1` restores from, so overwriting them would leave nothing to
  put back. Three index probes on a path that spends hundreds of milliseconds
  encoding AVIFs.
  """
  def frozen?(user_id, kind) when kind in @kinds do
    Repo.exists?(from(i in profile_query(user_id, kind), where: not is_nil(i.frozen_at)))
  end

  @doc "The member's row for this kind, or nil."
  def profile_image(user_id, kind) when kind in @kinds,
    do: Repo.one(profile_query(user_id, kind))

  @doc """
  Applies the AI gate's verdict to the member's row, guarded on the bytes that
  were scanned exactly as `Vutuv.Moderation.ImageSubjects` guards the member
  row. A nil fingerprint would raise rather than match nothing (`where: x ==
  ^nil` is not a silent no-op in Ecto), so it is answered as "no row".
  """
  def mark_moderation(user_id, kind, fingerprint, state)
      when kind in @kinds and is_binary(fingerprint) do
    user_id
    |> profile_query(kind)
    |> where([i], i.fingerprint == ^fingerprint)
    |> Repo.update_all(set: [moderation: state, updated_at: now()])

    :ok
  end

  def mark_moderation(_user_id, _kind, _fingerprint, _state), do: :ok

  @doc """
  Keeps the row's fingerprint in step when `Vutuv.Uploads.regenerate/3`
  re-derives a picture and writes a new one onto the member row. Takes the id
  the member row points at, so a picture that has no row yet — every one
  uploaded before this release, until #2014's backfill — costs no statement.
  """
  def sync_fingerprint(image_id, fingerprint) when is_binary(image_id) do
    from(i in Image, where: i.id == ^image_id)
    |> Repo.update_all(set: [fingerprint: fingerprint, updated_at: now()])

    :ok
  end

  def sync_fingerprint(nil, _fingerprint), do: :ok

  @doc """
  Drops the member's row for this kind — the picture is gone (the AI gate
  rejected it, or the scan was canceled because the bytes vanished). Deleting
  rather than blanking keeps "there is a row" and "there is a picture" the same
  statement.
  """
  def forget_profile_image(user_id, kind) when kind in @kinds do
    user_id |> profile_query(kind) |> Repo.delete_all()
    :ok
  end

  ## The copyright freeze (issue #2012)

  @doc """
  Takes this picture offline without deleting a byte of it: the row is stamped
  `frozen_at`, the member row's four columns for that kind are cleared, and
  every file moves into the hold (`Vutuv.Uploads.hold/3`).

  Clearing the member columns is what a reader notices. Every URL builder and
  every display gate still reads them (#2027 moves them onto the row), and
  "this member has no picture of that kind" is the one answer all of them
  already agree on — `Vutuv.Avatar.display_url/2` returns the silhouette, the
  vCard and the link-preview JPEG return nothing, the actor document drops its
  icon. Leaving them set and only moving the files would have given some sixty
  render sites a broken image instead.

  Nothing is lost by clearing them, because the row holds the same four values:
  `unfreeze/1` writes them back.

  **Order matters.** The stamp goes first: it is the record that this picture is
  meant to be held, so a slot that dies mid-move leaves a picture that is
  already invisible and a job `reconcile_holds/0` finishes. The other order
  would leave files in a hold that nothing knows to bring back.
  """
  def freeze(%Image{} = image) do
    # `is_nil(frozen_at)` so a second pass — `reconcile_holds/0` finishing an
    # interrupted move — re-asserts the freeze without moving the moment it
    # happened, which is what the case and the statement of reasons quote.
    {_count, _} =
      Repo.update_all(from(i in Image, where: i.id == ^image.id and is_nil(i.frozen_at)),
        set: [frozen_at: now(), updated_at: now()]
      )

    hide_from_member_row(image)

    with %User{} = user <- owner(image),
         do: @profile_columns[image.kind].module.hold(image.id, user)

    :ok
  end

  @doc """
  Puts a frozen picture back exactly where it was: every file returns to the
  tree it came from under the name it had, the member row gets its four columns
  back from the row, and the hold is removed.

  The URL therefore comes back unchanged, which is the point — other servers,
  search engines and sent mail all hold it. The one case where the bytes cannot
  simply move back is a member who renamed while their picture was held (the
  handle is baked into the served file name), so the same self-heal
  `Vutuv.Uploads.promote_from_quarantine/2` uses runs afterwards and re-derives
  from the original under the current handle.

  Idempotent, and safe to run again after an interruption: the hold is removed
  only once the member row names the files again, so a half-finished restore is
  still a hold for `reconcile_holds/0` to find.
  """
  def unfreeze(%Image{} = image) do
    {_count, _} =
      Repo.update_all(from(i in Image, where: i.id == ^image.id),
        set: [frozen_at: nil, updated_at: now()]
      )

    with %User{} = user <- owner(image) do
      config = @profile_columns[image.kind]
      config.module.release(image.id, user)

      show_on_member_row(image)
      config.module.regenerate(Repo.get!(User, user.id))
    end

    Uploads.purge_hold(image.id)
    :ok
  end

  @doc """
  Deletes this picture for good — every derived version, the private original
  and the held copies — and forgets the row. What an upheld copyright case does,
  and what the owner's own "remove it" does.

  The member row is cleared first, so an interruption can only ever leave files
  nothing points at (which `reconcile_holds/0` collects), never a member row
  naming files that are gone.
  """
  def purge(%Image{} = image) do
    case owner(image) do
      %User{} = user ->
        config = @profile_columns[image.kind]
        hide_from_member_row(image)
        # By id rather than through `forget_profile_image/2`, its (user_id,
        # kind) twin, so the kinds #2015 brings — which have no member owner —
        # take the same path.
        Repo.delete_all(from(i in Image, where: i.id == ^image.id))
        config.module.delete(user)

      nil ->
        Repo.delete_all(from(i in Image, where: i.id == ^image.id))
    end

    Uploads.purge_hold(image.id)
    :ok
  end

  @doc """
  Finishes every move a dying slot left half-done, in both directions — the
  standing job behind `freeze/1` and `unfreeze/1`, run by
  `Vutuv.Moderation.Sweeper` every 15 minutes.

  The row's `frozen_at` is the intent and the disk is the state, so this reads
  the intent and re-asserts it: a frozen picture has its member columns cleared
  again and whatever is left of it moved into the hold, a hold whose row is no
  longer frozen is released, and a hold whose row is gone (an upheld case
  interrupted between the two) is deleted. Every step is the same idempotent
  function the request path runs, so a second pass over finished work writes
  nothing.
  """
  def reconcile_holds do
    # Preloaded, so re-asserting a freeze costs no lookup per picture.
    frozen = Repo.all(from(i in Image, where: not is_nil(i.frozen_at), preload: :user))
    for image <- frozen, do: freeze(image)

    frozen_ids = MapSet.new(frozen, & &1.id)
    leftover = Enum.reject(Uploads.held_image_ids(), &MapSet.member?(frozen_ids, &1))

    release_leftover_holds(leftover)

    :ok
  end

  # A hold whose row is no longer frozen goes back; a hold whose row is gone
  # (an upheld case interrupted between the two) is deleted. One query for the
  # lot, however many there are.
  defp release_leftover_holds([]), do: :ok

  defp release_leftover_holds(image_ids) do
    rows = Repo.all(from(i in Image, where: i.id in ^image_ids, preload: :user))
    for image <- rows, do: unfreeze(image)

    known = MapSet.new(rows, & &1.id)
    for id <- image_ids, not MapSet.member?(known, id), do: Uploads.purge_hold(id)

    :ok
  end

  # The same four columns
  # `Vutuv.Moderation.ImageSubjects.clear_profile_columns/1` clears for a
  # rejected picture, minus the pointer: this row is still the member's picture
  # of that kind, it is only being held, and the pointer is how the case and
  # `unfreeze/1` find it again.
  #
  # Guarded on the file column, so a converged freeze — `reconcile_holds/0`
  # passing over work that is already done — matches no row and writes nothing.
  # Every reader is gated on that column, so a half-cleared row is invisible
  # either way.
  defp hide_from_member_row(%Image{user_id: user_id, kind: kind}) do
    config = @profile_columns[kind]

    Repo.update_all(
      from(u in User, where: u.id == ^user_id and not is_nil(field(u, ^config.file))),
      set: [
        {config.file, nil},
        {config.fingerprint, nil},
        {config.crop, nil},
        {config.moderation, nil}
      ]
    )

    :ok
  end

  # The pointer is deliberately left alone by both halves: it is true while the
  # picture is held (that row IS the member's picture), and a deleted row
  # nilifies it by itself.
  defp show_on_member_row(%Image{kind: kind} = image) do
    config = @profile_columns[kind]

    Repo.update_all(from(u in User, where: u.id == ^image.user_id),
      set: [
        {config.file, image.file},
        {config.fingerprint, image.fingerprint},
        {config.crop, image.crop},
        {config.moderation, image.moderation},
        {config.pointer, image.id}
      ]
    )

    :ok
  end

  # Takes the preload when it is there and looks the member up when it is not:
  # half the callers hand over a bare row straight from a query, and an answer
  # that depends on whether somebody remembered a preload is not an answer.
  defp owner(%Image{user: %User{} = user}), do: user
  defp owner(%Image{user_id: user_id}) when is_binary(user_id), do: Repo.get(User, user_id)
  defp owner(%Image{}), do: nil

  defp profile_query(user_id, kind),
    do: from(i in Image, where: i.user_id == ^user_id and i.kind == ^kind)

  defp now, do: NaiveDateTime.utc_now(:second)
end

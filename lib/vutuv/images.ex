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
      off switch is moving the bytes out of that tree (the quarantine tree the
      AI gate already uses, `Vutuv.Uploads.quarantine_dir/1`).
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

  @doc """
  The member-row column pointing at this kind's row. The one place that name is
  written; `Vutuv.Accounts`, `Vutuv.Uploads` and
  `Vutuv.Moderation.ImageSubjects` all read it from here.
  """
  def pointer_field("avatar"), do: :avatar_image_id
  def pointer_field("cover"), do: :cover_image_id

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
    attrs = Map.merge(attrs, %{kind: kind, user_id: user.id, token: Uploads.gen_token()})

    %Image{}
    |> Image.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:token, :file, :fingerprint, :crop, :moderation, :updated_at]},
      conflict_target: {:unsafe_fragment, "(user_id, kind) WHERE kind IN ('avatar', 'cover')"},
      returning: [:id]
    )
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

  defp profile_query(user_id, kind),
    do: from(i in Image, where: i.user_id == ^user_id and i.kind == ^kind)

  defp now, do: NaiveDateTime.utc_now(:second)
end

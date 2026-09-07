defmodule Vutuv.ImageHelpers do
  @moduledoc """
  A member's profile picture as both halves the application always writes: the
  four columns on the member row and the row in the shared `images` table
  (`Vutuv.Images`).

  Since #2027 every URL builder and every display gate reads the row, so a test
  that sets only `users.avatar` describes a member with no picture — a state no
  upload can produce. These two helpers put the pair there: `with_image_rows/1`
  for a member that is in the database, `put_image/3` for the struct-only tests
  that never insert one.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.Images
  alias Vutuv.Images.Image
  alias Vutuv.Repo

  alias Vutuv.UUIDv7

  @doc """
  Gives an **inserted** member the row its own columns already name, for each
  kind whose file column is set, and points the member row at it. Returns the
  member reloaded with both rows preloaded, so a later render costs no lookup.
  """
  def with_image_rows(%User{} = user) do
    pointers =
      for {kind, cols} <- Images.member_columns(),
          not is_nil(Map.get(user, cols.file)),
          into: [] do
        # Through the same function an upload goes through, so a fixture cannot
        # put a row in the database that no upload could write.
        {:ok, image} =
          Images.put_profile_image(user, kind, %{
            file: Map.get(user, cols.file),
            fingerprint: Map.get(user, cols.fingerprint),
            crop: Map.get(user, cols.crop),
            moderation: Map.get(user, cols.moderation)
          })

        {cols.pointer, image.id}
      end

    user
    |> Ecto.Changeset.change(Map.new(pointers))
    |> Repo.update!()
    |> Images.preload_member_images()
  end

  @doc """
  Hangs a picture row on a member **struct**, preloaded, without touching the
  database — what the URL-convention tests need, which never insert a member.
  `attrs` are the row's own columns (`:file`, `:fingerprint`, `:crop`,
  `:moderation`, `:frozen_at`).
  """
  def put_image(%User{} = user, kind, attrs) when kind in ["avatar", "cover"] do
    cols = Images.member_columns(kind)

    image =
      struct!(
        %Image{id: UUIDv7.generate(), kind: kind, user_id: user.id, token: "token-#{kind}"},
        attrs
      )

    user
    |> Map.put(cols.assoc, image)
    |> Map.put(cols.pointer, image.id)
  end

  @doc """
  The same as `put_image/3` for a member who has no picture of that kind: the
  association is loaded and empty, so nothing looks anything up.
  """
  def without_image(%User{} = user, kind) when kind in ["avatar", "cover"] do
    cols = Images.member_columns(kind)

    user
    |> Map.put(cols.assoc, nil)
    |> Map.put(cols.pointer, nil)
  end
end

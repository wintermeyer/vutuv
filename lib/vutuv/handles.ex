defmodule Vutuv.Handles do
  @moduledoc """
  The shared `@handle` namespace (issue #941): members (`users.username`) and
  organizations (`organizations.username`) live at the URL root (`/:handle`) in one
  namespace whose global uniqueness is guaranteed by the `handles` registry
  table's `UNIQUE(value)` index.

  Two responsibilities:

    * **Grammar** — `validate_handle/2` is the single definition of what a
      handle may look like (Twitter style, `^[a-z0-9_]+$`, `min_length/0` to
      `max_length/0` chars, never a reserved word), shared by the member and
      organization owner changesets so they cannot drift apart.
    * **Uniqueness sync** — `put_user_handle/2` / `put_organization_handle/2` upsert
      the owner's registry row inside the caller's transaction, so a claim that
      collides with any other member or organization loses on the unique index. This
      is the only place the cross-table lock is written; resolution reads the
      owner tables directly and never touches this module.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Vutuv.Accounts.Handle
  alias Vutuv.Accounts.ReservedSlugs
  alias Vutuv.Accounts.User
  alias Vutuv.Organizations.Organization
  alias Vutuv.Repo

  @format ~r/^[a-z0-9_]+$/
  # The single source of truth for the handle length bounds. Everything else
  # derives from `min_length/0` / `max_length/0`: the member (`User`) and
  # organization changesets (via `validate_handle/2`), the auto-generated handles
  # (`Vutuv.SlugHelpers`), the username form's `minlength`/`maxlength` + hint,
  # and the reserved-slug router guard. Change them here and nowhere else.
  @min_length 3
  @max_length 23

  def format, do: @format
  def min_length, do: @min_length
  def max_length, do: @max_length

  @doc """
  Validates the handle `field` (`:username`) on an owner changeset: lowercased,
  `^[a-z0-9_]+$`, #{@min_length}-#{@max_length} chars, never a `ReservedSlugs`
  word. Uniqueness is not checked here — that is the registry row's job — so
  this is safe to run on both the member and the organization path.
  """
  def validate_handle(changeset, field) do
    changeset
    |> update_change(field, &downcase/1)
    |> validate_format(field, @format,
      message: "may only contain letters, numbers, and underscores"
    )
    |> validate_length(field, min: @min_length, max: @max_length)
    |> validate_exclusion(field, ReservedSlugs.list(), message: "is reserved")
  end

  defp downcase(nil), do: nil
  defp downcase(value), do: String.downcase(value)

  @doc """
  Upserts the member's registry row to their current `username`. Runs against
  the transaction's `repo` so it is atomic with the member write; returns
  `{:ok, handle}` or `{:error, changeset}` (unique-index collision) for
  `Ecto.Multi.run/3`.
  """
  def put_user_handle(repo \\ Repo, %User{} = user) do
    (repo.get_by(Handle, user_id: user.id) || %Handle{user_id: user.id})
    |> Handle.changeset(user.username)
    |> repo.insert_or_update()
  end

  @doc """
  Upserts the organization's registry row to its current `username`. Same contract as
  `put_user_handle/2`.
  """
  def put_organization_handle(repo \\ Repo, %Organization{} = organization) do
    (repo.get_by(Handle, organization_id: organization.id) ||
       %Handle{organization_id: organization.id})
    |> Handle.changeset(organization.username)
    |> repo.insert_or_update()
  end

  @doc """
  Whether `value` is free to claim (not already owned by a member or organization,
  and not reserved). A convenience for pre-flight UI checks; the registry's
  unique index is still the authority at write time.
  """
  def available?(value) when is_binary(value) do
    normalized = downcase(value)

    normalized not in ReservedSlugs.list() and
      not Repo.exists?(from(h in Handle, where: h.value == ^normalized))
  end

  def available?(_), do: false
end

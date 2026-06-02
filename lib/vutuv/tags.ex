defmodule Vutuv.Tags do
  @moduledoc """
  The Tags context. Handles tags, user tags, and user tag endorsements.
  """

  import Ecto.Query

  alias Vutuv.Repo
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag
  alias Vutuv.Tags.UserTagEndorsement

  # ── Tags ──

  def list_tags do
    Repo.all(from(t in Tag, order_by: t.slug))
  end

  def get_tag!(id), do: Repo.get!(Tag, id)

  def get_tag_by_slug(slug) do
    Repo.get_by(Tag, slug: slug)
  end

  def create_tag(attrs) do
    %Tag{} |> Tag.changeset(attrs) |> Repo.insert()
  end

  def update_tag(%Tag{} = tag, attrs) do
    tag |> Tag.edit_changeset(attrs) |> Repo.update()
  end

  def delete_tag!(%Tag{} = tag), do: Repo.delete!(tag)

  # ── User Tags ──

  def list_user_tags(user), do: Repo.all(Ecto.assoc(user, :user_tags))

  def get_user_tag!(id), do: Repo.get!(UserTag, id)

  def create_user_tag(attrs) do
    %UserTag{} |> UserTag.changeset(attrs) |> Repo.insert()
  end

  def delete_user_tag!(%UserTag{} = user_tag), do: Repo.delete!(user_tag)

  # ── User Tag Endorsements ──

  def create_endorsement(attrs) do
    %UserTagEndorsement{} |> UserTagEndorsement.changeset(attrs) |> Repo.insert()
  end

  def delete_endorsement!(%UserTagEndorsement{} = endorsement), do: Repo.delete!(endorsement)

  def endorsement_count(user_tag_id), do: UserTagEndorsement.count(user_tag_id)

  def tag_endorsed?(user_tag_id, user_id),
    do: UserTagEndorsement.tag_endorsed?(user_tag_id, user_id)
end

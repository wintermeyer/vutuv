defmodule Vutuv.Organizations.OrganizationImage do
  @moduledoc """
  An image belonging to an organization page (issue #929) — the `post_images` pattern
  1:1. Today only the logo is uploaded (from the edit form); the `alt`/`position`
  columns and the second `organization_id`-nil "pending" lifecycle are carried for the
  description-gallery reuse job postings (#932) build on. Derived versions
  (`thumb`/`feed`/`large`) are metadata-stripped AVIF (`Vutuv.Uploads.Spec`);
  serving always goes through the authorizing proxy
  (`/organization_images/:token/:version`), keyed by the unguessable `token`, never
  the row id.
  """

  use VutuvWeb, :model

  alias Vutuv.Uploads.Spec

  @versions ~w(thumb feed large)

  schema "organization_images" do
    belongs_to(:organization, Vutuv.Organizations.Organization)
    belongs_to(:user, Vutuv.Accounts.User)

    field(:token, :string)
    field(:alt, :string, default: "")
    field(:position, :integer, default: 0)
    field(:width, :integer)
    field(:height, :integer)
    field(:content_type, :string)
    field(:size_bytes, :integer)

    # AI image moderation state (Vutuv.Moderation.ImageScans). DB default is
    # "pending", so an image is invisible-to-others until released.
    field(:moderation, :string, default: "pending")

    timestamps()
  end

  @doc "A fresh unguessable URL token (~128 bits, URL-safe)."
  def gen_token do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc "Root-relative proxy URL for a version of a stored token (the logo column)."
  def token_url(token, version) when is_binary(token) and version in @versions do
    "/organization_images/#{token}/#{version}#{Spec.served_ext()}"
  end

  def token_url(_, _), do: nil
end

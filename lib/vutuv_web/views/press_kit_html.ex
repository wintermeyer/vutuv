defmodule VutuvWeb.PressKitHTML do
  @moduledoc """
  The public press page — `/:slug/press` for a member (issue #2086) and
  `/organizations/:slug/press` for a page (issue #2087). Everything it draws is
  `VutuvWeb.PressKitComponents`, shared with the profile card and the page's
  card; what lives here is the one template and the three things about it that
  differ per owner kind — its title, its breadcrumb trail and where its owner
  goes to edit it.

  Those three are functions rather than assigns the controller passes, so the
  page keeps one template and the controller keeps no view knowledge.
  """
  use VutuvWeb, :html

  import VutuvWeb.PressKitComponents

  alias Vutuv.Identity
  alias Vutuv.Organizations.Organization
  alias Vutuv.PressKit
  alias VutuvWeb.UserHelpers

  embed_templates("../templates/press_kit/*")

  @doc """
  The page's `<title>`: the owner's name and the section, in the one shape
  every other public sub-page wears.
  """
  def press_page_title(owner), do: UserHelpers.member_page_title(owner, gettext("Press"))

  @doc "The page's heading, which names its owner rather than a bare category."
  def press_heading(owner),
    do: gettext("Press photos and logos of %{name}", name: Identity.display_name(owner))

  @doc """
  The breadcrumb trail: the owner's own listing, the owner, this page.

  The middle crumb asks the identity rather than matching the owner kind a
  second time (`Identity.path/1` for a page *is*
  `Organizations.canonical_path/1`), so only the first word branches — the
  listing each kind belongs to, in the msgid that listing already uses.
  """
  def press_crumbs(owner),
    do: [
      owner_listing(owner),
      {Identity.display_name(owner), Identity.path(owner)},
      gettext("Press")
    ]

  defp owner_listing(%Organization{}), do: gettext("Organizations")
  defp owner_listing(_owner), do: gettext("Users")

  @doc """
  Where this viewer edits this kit, or `false` — `<.page_header>`'s quiet
  "Manage ›" bridge, the same one every profile section page carries.

  One question for both owner kinds, `Vutuv.PressKit.manageable_by?/2`: a
  member their own, a page's **owner or publisher**. Deliberately not
  `Organizations.can_manage?/2`, the manage menu's usual gate — that one also
  counts the member who claimed the page whether or not they still hold a role,
  and writing a press kit follows the roles. It costs a role read only for a
  signed-in viewer, since that predicate answers an anonymous one from its
  catch-all clause without touching the database.
  """
  def press_manage_to(owner, viewer),
    do: PressKit.manageable_by?(owner, viewer) and PressKit.editor_path(owner)
end

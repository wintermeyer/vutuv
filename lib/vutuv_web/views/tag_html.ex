defmodule VutuvWeb.TagHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.FediverseComponents, only: [remote_follow_form: 1]
  import VutuvWeb.UserHelpers
  import VutuvWeb.JobComponents, only: [job_card: 1]
  alias Vutuv.Tags.Tag

  # The front-matter card's own assigns, loaded at most once per render. Both
  # the card and the page that decides whether to draw a wrapper around it need
  # them, and the loads behind them are four queries — so whoever asks first
  # pays, and the second call is a map lookup. `/:slug/tags/:tag` still calls
  # `single_card/1` with bare assigns and gets the loads there, as before.
  defp enrich(%{tag_description: _} = assigns), do: assigns
  defp enrich(assigns), do: update_assigns(assigns)

  defp update_assigns(assigns) do
    related_users = Tag.related_users(assigns[:tag], assigns[:current_user])
    recommended_users = Tag.recommended_users(assigns[:tag])

    # Batch the per-row work-info / follow lookups for both lists (one query
    # each), so card_list runs no per-user queries — same scheme as the
    # listing pages and the profile rail.
    users = related_users ++ recommended_users

    assigns
    |> Map.put(:related_users, related_users)
    |> Map.put(:recommended_users, recommended_users)
    |> Map.put(:tag_aliases, Tag.aliases_of(assigns[:tag]))
    # One reading of "has a description", so the card's heading and the test
    # that decides whether the card exists at all cannot disagree over a blank
    # string somebody saved in the admin form.
    |> Map.put(:tag_description, presence(assigns[:tag].description))
    |> Map.put(:work_string_length, 45)
    |> Map.put(:work_info_by_id, work_information_map(users, 45))
    |> Map.put(:following_by_id, following_map(assigns[:current_user], users))
  end

  defp presence(nil), do: nil

  defp presence(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      _ -> text
    end
  end

  # Whether the front-matter card has anything in it at all: the admin-written
  # description, the alternative names, and the two people lists. `description`
  # is editable only under `/admin/tags/:slug`, and most tags carry none and no
  # endorsed members either — so on most tag pages all four are empty and the
  # card would be a white box saying nothing, directly above the posts the
  # reader came for. Then it does not render.
  defp tag_front_matter?(assigns) do
    not is_nil(assigns.tag_description) or assigns.tag_aliases != [] or
      assigns.related_users != [] or assigns.recommended_users != []
  end

  @doc """
  The other names this topic answers to, as one comma-separated line.

  A reader who typed `ROR` and landed on Ruby on Rails has to be able to see
  why, so the page says so plainly (issue #1338) rather than leaving the
  redirect unexplained. The names are the alias rows' own, in the casing their
  first writer used.
  """
  def alias_names(aliases), do: Enum.map_join(aliases, ", ", & &1.name)

  attr(:tag, :map, required: true)
  attr(:handle, :string, required: true, doc: "`@slug@tags.<host>`, from the controller")
  attr(:class, :any, default: nil)

  @doc """
  This topic's address out in the Fediverse, and the way to follow it from
  wherever the reader's own account lives (issue #1330).

  **One card, two homes, and which one it gets is the reader's sign-in state.**
  Signed out it leads the page: somebody reading a topic here without an account
  is the visitor this exists for, and the card is their only way in — the follow
  pill in the header is not rendered for them at all. Signed in it sits at the
  foot of the page: a member follows the topic with that pill, so the address
  out there is a thing they may want once, and for months it was ~300px of the
  space above the posts they actually came for.

  The card itself is identical either way, so the two placements cannot drift
  into two different explanations of the same thing. It is composed here rather
  than reusing `follow_us_from_elsewhere/1` because a topic is not a person: the
  sentence names the hashtag, and the profile's version has a full name in it.
  """
  def tag_fediverse_card(assigns) do
    ~H"""
    <.card id="tag-fediverse" class={@class}>
      <div class="flex items-start gap-3">
        <span class="mt-0.5 shrink-0 rounded-lg bg-brand-50 p-2 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100">
          <.detail_icon name="globe" class="h-5 w-5" />
        </span>
        <div class="min-w-0 flex-1">
          <.section_title class="dark:text-slate-400">
            {gettext("Follow from the Fediverse")}
          </.section_title>
          <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {gettext(
              "Follow #%{tag} from Mastodon or any other Fediverse app and its public posts arrive in your timeline. No vutuv account needed.",
              tag: @tag.slug
            )}
          </p>
          <.copy_field id="tag-fediverse-handle">{@handle}</.copy_field>
          <.remote_follow_form action={~p"/tags/#{@tag.slug}/fediverse/follow"} />
        </div>
      </div>
    </.card>
    """
  end

  embed_templates("../templates/tag/*")
end

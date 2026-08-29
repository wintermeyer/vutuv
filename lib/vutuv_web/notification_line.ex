defmodule VutuvWeb.NotificationLine do
  @moduledoc """
  What one notification says, and where it leads.

  A notification is derived with an English `:text` and a `:kind`; the wording
  is rendered from the **kind** so it follows whoever is reading, not whoever
  triggered it. Most kinds read as a verb phrase that follows the actor's name
  ("replied to your post."); the few with no actor - moderation, a rejected
  image, a finished reference check - are whole sentences.

  Two surfaces share it, which is why it lives here rather than in either:
  `VutuvWeb.NotificationLive.Index` (the page under the bell) and
  `VutuvWeb.ShellLive`, which puts the same line into a **browser**
  notification (issue #1249). A second copy would drift the moment a kind is
  added, and the popup would quietly go back to the untranslated English
  `:text` fallback.

  `notification_target/2` lives here for the same reason and is the half that
  is easiest to leave behind: a popup is raised precisely when the member is
  *not* looking at vutuv, so dropping them on the notifications list to hunt
  for the thing they were just told about is the one place that costs most.
  One function owns where a notification leads, so a new kind is answered once.

  The third per-kind wording is `VutuvWeb.NotificationDigestText`, which stays
  its own module on purpose: a digest mail names the actor inline and by
  `@handle`, quotes nothing, and survives having no clause for a kind. The
  fourth is `VutuvWeb.PushLine` (issue #1729), and it is the odd one out: a Web
  Push may not carry content at all, so it says only what *sort* of thing
  happened and folds every kind it has no line for into one. When you add a
  kind, spell it in the first three — the fourth is meant to stay short.
  """
  use Gettext, backend: VutuvWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  import VutuvWeb.UI, only: [compact_count: 1]

  alias VutuvWeb.UserHelpers

  # The event text for the ungrouped kinds, rendered from the kind (not
  # stored) so it translates with the viewer's locale. Unknown kinds fall
  # back to the pushed text.
  # The only row here with no actor in front of it, so it is a whole sentence
  # rather than a verb phrase. It names the Zeugnis, because a member with
  # several of them is otherwise told only that "a" review is ready, and it
  # names the grade when the report stated one — that is the fact they have
  # been waiting minutes for, and burying it one click deeper would be a tease.
  def notification_text(%{kind: "reference_check"} = n) do
    case {n[:title], n[:grade]} do
      {title, grade} when is_binary(title) and is_binary(grade) ->
        gettext("The review of “%{title}” is ready: %{grade}.", title: title, grade: grade)

      {title, _none} when is_binary(title) ->
        gettext("The review of “%{title}” is ready.", title: title)

      _untitled ->
        gettext("Your employment reference has been reviewed.")
    end
  end

  def notification_text(%{kind: "reply"}), do: gettext("replied to your post.")

  # The four everyday kinds. They used to be spelled only in the notifications
  # page's grouping code, where a row can stand for several actors, so a single
  # one of them fell through to the untranslated English `:text` the event was
  # stored with - invisible on that page (its groups always take the grouped
  # branch) and very visible in a browser notification, which is one event by
  # definition. The grouped multi-actor forms stay where they are; the
  # single-actor ones live here and both pages share them.
  def notification_text(%{kind: "like"}), do: gettext("liked your post.")

  def notification_text(%{kind: "follower"}), do: gettext("started following you.")

  def notification_text(%{kind: "connection"}), do: gettext("is now connected with you.")

  # The live-pushed endorsement names one tag (`:tag`); the page's grouped row
  # merges an endorser's several into a `:tags` list and keeps its own clause.
  def notification_text(%{kind: "endorsement", tag: tag}) when is_binary(tag),
    do: gettext("endorsed you for %{tag}.", tag: tag)

  def notification_text(%{kind: "mention"}), do: gettext("mentioned you in a post.")

  def notification_text(%{kind: "fediverse_reply"}),
    do: gettext("replied to your post from another network.")

  # Live-pushed reactions land here (no group context yet): one actor. The verb
  # is the whole point of the news, so `fediverse_reaction_text/2` owns both
  # sentences and this and the grouped row share them.
  def notification_text(%{kind: "fediverse_reaction"} = n),
    do: fediverse_reaction_text(n[:reaction_kind], 1)

  # Live-pushed thread events land here (no group context yet): one actor.
  def notification_text(%{kind: "thread"}), do: thread_text(1)

  def notification_text(%{kind: "organization_role"} = n) do
    case n[:role] do
      "owner" ->
        gettext("made you an owner of %{organization}.", organization: n.organization_name)

      "admin" ->
        gettext("made you an admin of %{organization}.", organization: n.organization_name)

      "recruiter" ->
        gettext("made you a recruiter for %{organization}.", organization: n.organization_name)

      _ ->
        gettext("gave you a role at %{organization}.", organization: n.organization_name)
    end
  end

  # Moderation items carry no actor (reports are anonymous); the text alone
  # tells the owner what happened and links to the case page.
  def notification_text(%{kind: "moderation"} = n) do
    case n[:status] do
      "upheld" -> gettext("A report about your content was confirmed.")
      "rejected" -> gettext("A report about your content was dismissed; it is visible again.")
      "resolved_edited" -> gettext("You revised reported content; the case is closed.")
      "resolved_deleted" -> gettext("You deleted reported content; the case is closed.")
      _ -> gettext("Your content was reported and is hidden while the report is handled.")
    end
  end

  # The AI image scan removed an image. No actor (it was the machine); the
  # what-was-removed wording shares its single source with the email
  # (VutuvWeb.UserHelpers.image_kind_label/2). The line says outright that a
  # machine decided and can be wrong — a bare "your image was removed" reads
  # as a person's judgement on the member.
  def notification_text(%{kind: "image_rejected"} = n) do
    what = UserHelpers.image_kind_label(n[:image_kind], Gettext.get_locale(VutuvWeb.Gettext))

    gettext(
      "An AI, not a person, removed %{what}: it judged the image not family-friendly enough for a work environment. It can be wrong, so reply to our email if you disagree.",
      what: what
    )
  end

  # Reporter protection: the actor is the *reported* member, rendered as
  # @handle by the actor line; the text explains the both-ways pause and
  # that an unfounded ruling undoes it.
  def notification_text(%{kind: "report_protection"} = n) do
    case n[:status] do
      "restored" ->
        gettext(
          "Our admins found your report unfounded; the paused connection between you two is restored."
        )

      _ ->
        gettext(
          "Your report paused the connection between you two - no contact in either direction for now. If our admins find the report unfounded, this is undone."
        )
    end
  end

  # A handle change: show the old and new handle so the reader sees exactly
  # what was rewritten in their posts (before/after).
  def notification_text(%{kind: "handle_change"} = n) do
    gettext("changed their handle from @%{old} to @%{new}.",
      old: n.old_handle,
      new: n.new_handle
    )
  end

  # New CV entries the author chose to announce (issue #980). A lone entry
  # gets the section-specific wording, so a reader can tell a job from a
  # degree without opening it; a group of them is counted and listed below.
  def notification_text(%{kind: "cv_update", entries: [entry]}) do
    case entry.section do
      "educations" ->
        gettext("added a new education entry to their CV: %{entry}",
          entry: cv_entry_label(entry)
        )

      "qualifications" ->
        gettext("added a new certificate to their CV: %{entry}", entry: cv_entry_label(entry))

      _ ->
        gettext("added a new position to their CV: %{entry}", entry: cv_entry_label(entry))
    end
  end

  def notification_text(%{kind: "cv_update"} = n) do
    gettext("added %{count} new entries to their CV:",
      count: compact_count(n[:entry_count] || 0)
    )
  end

  # A kind with no clause above still reads as something, and reads it in the
  # member's language. The stored `:text` comes first because it is a real
  # sentence and says more; it is English, so where a kind is missing entirely
  # the generic line is the honest floor. `VutuvWeb.NotificationDigestText`
  # makes the same promise for the digest mail.
  def notification_text(n), do: n[:text] || gettext("Something new happened on your account.")

  @doc """
  The popup's two halves: an actor's name over their verb phrase.

  Most kinds read as a phrase that follows a name ("Anna Klein" / "replied to
  your post."), which is how the row under the bell reads. The kinds with no
  actor - a moderation ruling, a removed image, a finished reference check -
  are whole sentences already, so the sentence IS the title and there is no
  body: a placeholder name over one line would say less, not more.
  """
  def title_and_body(notification) do
    text = notification_text(notification)

    case notification[:actor_name] do
      name when is_binary(name) and name != "" -> {name, text}
      _actorless -> {text, nil}
    end
  end

  # German conjugates the verb across the actor count (hat/haben) where English
  # does not, so both branches go through ngettext even when the two English
  # forms read the same — the same trick `thread_text/1` uses.
  def fediverse_reaction_text("announce", count) do
    ngettext(
      "shared your post on another network.",
      "shared your post on another network.",
      count
    )
  end

  def fediverse_reaction_text("like", count) do
    ngettext(
      "liked your post on another network.",
      "liked your post on another network.",
      count
    )
  end

  def fediverse_reaction_text(_kind, count) do
    ngettext(
      "reacted to your post from another network.",
      "reacted to your post from another network.",
      count
    )
  end

  # The English tail is number-blind ("A and B replied in..."), but German
  # conjugates the verb (hat/haben), so the actor count goes through ngettext
  # even though both English forms read the same.
  def thread_text(count) do
    ngettext(
      "replied in a thread you posted in.",
      "replied in a thread you posted in.",
      count
    )
  end

  # "Head of Bridges · Span AG": what the entry is, then where. Either half
  # can be missing, so the separator only appears when both are there.
  def cv_entry_label(entry) do
    [entry.title, entry.subtitle]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  @doc """
  Where a notification leads, for a caller that must land the reader
  *somewhere* — a browser popup or a Web Push, both of which are raised
  precisely when the member is NOT looking at vutuv.

  The twin of `notification_target/2`, which answers `nil` for a kind with no
  page of its own, because the notifications page needs to know that a row is
  not a link. A popup does not: sending the reader to the bell is worse than
  the post, and better than nothing at all. Two callers had that fallback
  written out beside them; the next kind that changes it should not have to be
  remembered in three places.
  """
  def notification_url(notification, viewer),
    do: notification_target(notification, viewer) || ~p"/notifications"

  # Where clicking the event text leads. Events about one of the viewer's
  # posts open that post's thread; an endorsement the viewer's tags;
  # everything else the actor's profile. Moderation events lead to the
  # owner's case page (and carry no actor).
  def notification_target(%{kind: "moderation"} = n, viewer) do
    if is_binary(n[:case_id]) and viewer != nil, do: ~p"/moderation/cases/#{n.case_id}"
  end

  # An organization-role grant opens the organization page it was granted on.
  def notification_target(%{kind: "organization_role"} = n, _viewer) do
    if is_binary(n[:organization_slug]), do: ~p"/organizations/#{n.organization_slug}"
  end

  # A removed avatar/cover leads to the photos form (upload a new one), a
  # removed qualification proof to the credentials editor; other rejected
  # images have no page left to open.
  def notification_target(%{kind: "image_rejected"} = n, viewer) do
    cond do
      viewer == nil -> nil
      n[:image_kind] in ["avatar", "cover"] -> ~p"/settings/profile"
      n[:image_kind] == "qualification_document" -> ~p"/settings/qualifications"
      n[:image_kind] == "job_reference_document" -> ~p"/settings/job_references"
      true -> nil
    end
  end

  # The username note carries its own two links inside the sentence
  # (username_line/1), so the row itself must not be one.
  def notification_target(%{kind: "username"}, _viewer), do: nil

  # Straight to the report the member has been waiting for.
  def notification_target(%{kind: "reference_check"} = n, viewer) do
    if viewer && is_binary(n[:job_reference_id]),
      do: ~p"/settings/job_references/#{n.job_reference_id}/check"
  end

  # A CV update (issue #980) opens the entry itself when the group holds
  # exactly one; a bigger group leads to the author's profile, where all of
  # them sit (the entries are listed and individually linked under the line).
  def notification_target(%{kind: "cv_update"} = n, _viewer) do
    case n[:entries] do
      [entry] -> cv_entry_path(n, entry)
      _ -> actor_target(n)
    end
  end

  # A mention opens the post that named the reader, and a thread event the new
  # reply — both belong to the *actor*, not to the reader, unlike reply/like
  # below. The row carries that permalink ready-made (`Vutuv.Activity`, built
  # through `Posts.path/2`): assembling it here from `actor_param` linked a
  # page's mention into the member namespace, where nothing answers.
  def notification_target(%{kind: kind} = n, _viewer) when kind in ["mention", "thread"] do
    n[:post_path] || actor_target(n)
  end

  def notification_target(n, viewer) do
    primary_target(n, viewer) || actor_target(n)
  end

  # A reply from another network (issue #1069) opens the reader's **own** post,
  # where the reply card sits among the rest of the conversation — deliberately
  # not the remote original, which the card itself links to. The reader stays on
  # vutuv unless they choose otherwise, and a private reply (issue #1071) has no
  # public page to open anyway.
  def primary_target(%{kind: kind} = n, viewer)
      when kind in ["reply", "like", "fediverse_reply", "fediverse_reaction"] do
    if is_binary(n[:post_id]) and viewer != nil, do: ~p"/#{viewer}/posts/#{n.post_id}"
  end

  def primary_target(%{kind: "endorsement"}, viewer) when viewer != nil,
    do: ~p"/#{viewer}/tags"

  def primary_target(_n, _viewer), do: nil

  # A member's param is their handle and lives at the root; a page's is a slug
  # that lives under /organizations/:slug (issue #1336). Building this from the
  # param alone would point into the member namespace, at a word somebody else
  # may hold — so the row's own `actor_kind` decides, and a row without one
  # reads as the member it was.
  def actor_target(%{actor_kind: "organization", actor_param: slug}) when is_binary(slug),
    do: ~p"/organizations/#{slug}"

  def actor_target(n) do
    if is_binary(n[:actor_param]), do: ~p"/#{n.actor_param}"
  end

  # One entry's own page under the author's profile.
  def cv_entry_path(n, entry) do
    with slug when is_binary(slug) <- n[:actor_param],
         param when is_binary(param) <- entry.param do
      case entry.section do
        "work_experiences" -> ~p"/#{slug}/work_experiences/#{param}"
        "educations" -> ~p"/#{slug}/educations/#{param}"
        "qualifications" -> ~p"/#{slug}/qualifications/#{param}"
        _ -> ~p"/#{slug}"
      end
    else
      _ -> nil
    end
  end
end

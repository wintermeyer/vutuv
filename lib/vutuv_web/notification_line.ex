defmodule VutuvWeb.NotificationLine do
  @moduledoc """
  What one notification says, and where it leads.

  A notification is derived with an English `:text` and a `:kind`; the wording
  is rendered from the **kind** so it follows whoever is reading, not whoever
  triggered it. Most kinds read as a verb phrase that follows the actor's name
  ("replied to your post."); the few with no actor - moderation, a rejected
  image, a finished reference check - are whole sentences.

  Three surfaces share it, which is why it lives here rather than in any of
  them: `VutuvWeb.NotificationLive.Index` (the page under the bell) and
  `VutuvWeb.ShellLive` twice over — the **browser** notification it raises
  (issue #1249) and the **hover preview** under the bell itself, which shows
  the member what the badge's number stands for. A second copy would drift the
  moment a kind is added, and the popup would quietly go back to the
  untranslated English `:text` fallback.

  `kind_glyph/1`, `kind_classes/1` and `kind_label/1` are here for the same
  reason one step further: the preview draws the same little round badge the
  page draws, so the vocabulary of what a kind looks like is one table too.

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

  # The same event for an owner of the **page** the content belongs to (issue
  # #2120), who is told about it without being the member it is about: "your
  # content" would be a false sentence for them, and the page's name is the one
  # fact that tells them which of their pages lost something.
  def notification_text(%{kind: "moderation", organization_name: page} = n)
      when is_binary(page) do
    case n[:status] do
      "upheld" ->
        gettext("A report about content on %{page} was confirmed.", page: page)

      "rejected" ->
        gettext("A report about content on %{page} was dismissed; it is visible again.",
          page: page
        )

      status when status in ["resolved_edited", "resolved_deleted"] ->
        gettext("The case about content on %{page} is closed.", page: page)

      _open ->
        gettext("Content on %{page} was hidden after a report. Open the case to see why.",
          page: page
        )
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
      _ -> content_hidden_text(n[:category])
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

  # How a case this member reported ended (issue #2011). No actor, like every
  # other moderation line: naming the owner of the reported content would tell
  # a reporter something about somebody else's account. The wording matches the
  # mail's four endings; `upheld` deliberately does not claim the content was
  # removed, because an upheld profile case ends in a strike and a visible
  # profile (see `Vutuv.Moderation.reporter_outcome/1`).
  def notification_text(%{kind: "report_outcome"} = n) do
    case n[:outcome] do
      "removed" ->
        gettext("The content you reported was deleted; the case is closed.")

      "revised" ->
        gettext("The owner revised the content you reported; it is visible again.")

      "upheld" ->
        gettext("A person read your report and upheld it. Thank you.")

      _ ->
        gettext("A person read your report and did not uphold it; the content stays.")
    end
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

  # The line the owner reads the moment their content goes dark. It names what
  # was claimed and says outright that no person decided it, because "your
  # content was reported" leaves both open; the rest of the statement of
  # reasons (the reporter's own words, the ground, the options) is on the case
  # page the line links to.
  defp content_hidden_text(category) when is_binary(category) do
    gettext("Hidden automatically after a report: %{reason}. The case page says what you can do.",
      reason: VutuvWeb.ReportHTML.category_label(category)
    )
  end

  defp content_hidden_text(_missing) do
    gettext(
      "Your content was hidden automatically after a report. The case page says what you can do."
    )
  end

  # Event kinds that share the brand badge colour, so the class string lives
  # in one place.
  @brand_kind_classes "bg-brand-50 text-brand-700 dark:bg-brand-800/60 dark:text-brand-100"
  @brand_kinds ~w(follower reply thread mention connection report_protection organization_role handle_change cv_update fediverse_reply fediverse_reaction share)
  @moderation_kinds ~w(moderation image_rejected report_outcome)

  @doc """
  How one notification kind is *drawn*: the badge colour, the glyph inside it
  and the accessible name that says in words what the glyph means.

  Beside the wording above, because a surface that renders a notification needs
  both halves and there is now a third of them (the bell's hover preview in
  `VutuvWeb.ShellLive`, next to the notifications page and the browser popup).
  A raw kind string ("cv_update") must never reach a reader, which is what
  `kind_label/1` is for — it is the badge's `title` and its screen-reader text.
  """
  def kind_classes("endorsement"),
    do: "bg-emerald-50 text-emerald-600 dark:bg-emerald-900/30 dark:text-emerald-300"

  def kind_classes("like"), do: "bg-accent/10 text-accent dark:bg-accent/20"

  # Amber is the app's moderation colour: a case on the member's own content, an
  # image the AI scan removed, and a ruling on something they reported all read
  # as the same kind of news.
  def kind_classes(kind) when kind in @moderation_kinds,
    do: "bg-amber-50 text-amber-600 dark:bg-amber-900/30 dark:text-amber-200"

  def kind_classes(kind) when kind in @brand_kinds, do: @brand_kind_classes

  def kind_classes(_), do: "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-300"

  def kind_glyph("follower"), do: "+"
  def kind_glyph("endorsement"), do: "★"
  def kind_glyph("reply"), do: "↩"
  # A reply elsewhere in a thread the recipient writes in.
  def kind_glyph("thread"), do: "⤷"
  # Being named by @handle. Shares the glyph with the (rare, "More"-chip)
  # handle-change kind: both are about a handle, and the badge's title/sr-only
  # label tells them apart where the glyph alone would not.
  def kind_glyph("mention"), do: "@"
  def kind_glyph("like"), do: "♥"
  # A re-share from another network (issue #1068): the arrows, since the line
  # beside it names the verb and the globe already sits on the sharer's name.
  def kind_glyph("share"), do: "↻"
  # A reply written on another network (issue #1069) — the same globe the
  # post card's "from other networks" line uses, so one glyph means one thing.
  def kind_glyph("fediverse_reply"), do: "🌐"
  # A reaction from out there of a kind that is neither a favourite nor a
  # re-share — the globe, since "this came from another network" is the one
  # thing the glyph has to say; the sentence beside it names the verb.
  def kind_glyph("fediverse_reaction"), do: "🌐"
  # "connection" is the vernetzt (mutual-follow) event; the handshake glyph.
  def kind_glyph("connection"), do: "🤝"
  # The flag: raised against this member's content, or raised by them and now
  # answered. The badge's title tells the two apart where the glyph cannot.
  def kind_glyph(kind) when kind in ["moderation", "report_outcome"], do: "⚑"
  def kind_glyph("image_rejected"), do: "🖼"
  def kind_glyph("report_protection"), do: "🛡"
  def kind_glyph("organization_role"), do: "🏢"
  def kind_glyph("handle_change"), do: "@"
  def kind_glyph("cv_update"), do: "📄"
  # The welcome note naming the member's own handle.
  def kind_glyph("username"), do: "👋"
  # The finished AI reading of an Arbeitszeugnis. The magnifier, not a robot:
  # what arrived is a close reading of wording, and the member is being told to
  # go and read it.
  def kind_glyph("reference_check"), do: "🔍"
  def kind_glyph(_), do: "•"

  # The accessible kind name (the badge's title + sr-only text). Translated
  # like the row text; raw kind strings ("cv_update") must not leak to users.
  def kind_label("follower"), do: gettext("Follower")
  def kind_label("endorsement"), do: gettext("Endorsement")
  def kind_label("reply"), do: gettext("Reply")
  def kind_label("thread"), do: gettext("Thread reply")
  def kind_label("mention"), do: gettext("Mention")
  def kind_label("like"), do: gettext("Like")
  def kind_label("fediverse_reply"), do: gettext("Reply from another network")
  def kind_label("share"), do: gettext("Reaction from another network")
  def kind_label("fediverse_reaction"), do: gettext("Reaction from another network")
  def kind_label("connection"), do: gettext("Connection")
  def kind_label("moderation"), do: gettext("Moderation")
  def kind_label("image_rejected"), do: gettext("Image review")
  def kind_label("report_outcome"), do: gettext("Report decision")
  def kind_label("report_protection"), do: gettext("Report protection")
  def kind_label("organization_role"), do: gettext("Organization role")
  def kind_label("handle_change"), do: gettext("Handle change")
  def kind_label("cv_update"), do: gettext("CV update")
  def kind_label("username"), do: gettext("Username")
  def kind_label("reference_check"), do: gettext("Employment reference review")
  def kind_label(_), do: gettext("Activity")

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
  # removed qualification proof to the credentials editor, a refused press
  # picture to the press kit it was refused from (issue #2085); other rejected
  # images have no page left to open.
  def notification_target(%{kind: "image_rejected"} = n, viewer) do
    cond do
      viewer == nil -> nil
      n[:image_kind] in ["avatar", "cover"] -> ~p"/settings/profile"
      n[:image_kind] == "qualification_document" -> ~p"/settings/qualifications"
      n[:image_kind] == "job_reference_document" -> ~p"/settings/job_references"
      # The member's own press kit. A picture refused from a **page's** kit
      # names its uploader too and lands them here rather than on the page —
      # the row is deleted by then and the notification carries only the kind,
      # so nothing left can tell the two apart. A real page one click from the
      # right one beats the unclickable line #2084 left behind; #2087 owns the
      # page's editor.
      n[:image_kind] == "press_kit" -> ~p"/settings/media-kit"
      true -> nil
    end
  end

  # The username note carries its own two links inside the sentence
  # (username_line/1), so the row itself must not be one.
  def notification_target(%{kind: "username"}, _viewer), do: nil

  # A ruling on a report has no page for the *reporter*: the case page belongs
  # to the owner and the admins (`ModerationCaseController.authorize/2`), and
  # the content it was about may be gone. The sentence is the whole thing.
  def notification_target(%{kind: "report_outcome"}, _viewer), do: nil

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

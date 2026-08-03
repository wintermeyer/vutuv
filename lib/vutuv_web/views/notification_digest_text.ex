defmodule VutuvWeb.NotificationDigestText do
  @moduledoc """
  One plain line per notification, for the digest mail
  (`Vutuv.Activity.Digest`).

  Deliberately **not** the sentences `VutuvWeb.NotificationLive.Index` renders:
  that page groups several actors into one row, links each of them, quotes the
  post a like refers to and clamps it to the reader's line budget. None of that
  survives an email, and half of it should not travel by mail at all. What a
  digest owes the reader is enough to decide whether to open vutuv, and the
  page itself is one click away.

  So each line names *what happened* and, where there is one, *who did it* — a
  handle, never a display name, matching the house rule that system messages
  use handles. Nothing quotes a post body.

  A kind with no clause here still produces a line — a dull, true one — so a
  kind added tomorrow reaches the inbox rather than crashing the sweep or
  arriving blank.
  """

  use Gettext, backend: VutuvWeb.Gettext

  @doc "The line for one notification item, as plain text."
  def line(%{kind: "follower"} = item),
    do: gettext("%{who} started following you.", who: handle(item))

  def line(%{kind: "connection"} = item),
    do: gettext("You and %{who} are now connected.", who: handle(item))

  def line(%{kind: "endorsement", tag: tag} = item) when is_binary(tag),
    do: gettext("%{who} endorsed you for %{tag}.", who: handle(item), tag: tag)

  def line(%{kind: "endorsement"} = item),
    do: gettext("%{who} endorsed one of your tags.", who: handle(item))

  def line(%{kind: "reply"} = item),
    do: gettext("%{who} replied to your post.", who: handle(item))

  def line(%{kind: "thread"} = item),
    do: gettext("%{who} answered in a conversation you are part of.", who: handle(item))

  def line(%{kind: "mention"} = item),
    do: gettext("%{who} mentioned you in a post.", who: handle(item))

  def line(%{kind: "like"} = item),
    do: gettext("%{who} liked your post.", who: handle(item))

  def line(%{kind: "fediverse_reply"} = item),
    do: gettext("%{who} replied to your post from another network.", who: handle(item))

  def line(%{kind: "fediverse_reaction"} = item),
    do: gettext("%{who} reacted to your post from another network.", who: handle(item))

  def line(%{kind: "organization_role", organization_name: name}) when is_binary(name),
    do: gettext("You were given a role at %{organization}.", organization: name)

  def line(%{kind: "cv_update"} = item),
    do: gettext("%{who} added something to their CV.", who: handle(item))

  def line(%{kind: "handle_change", old_handle: old, new_handle: new})
      when is_binary(old) and is_binary(new),
      do: gettext("@%{old} is now @%{new}.", old: old, new: new)

  def line(%{kind: "moderation"}),
    do: gettext("A moderation case on your account was updated.")

  def line(%{kind: "image_rejected"}),
    do: gettext("One of your images was removed by the image review.")

  def line(%{kind: "report_protection"}),
    do: gettext("A report you are involved in changed something on your account.")

  def line(%{kind: "username"}),
    do: gettext("Your vutuv username is ready.")

  # The one line that carries a value rather than an actor, because the value
  # is the whole reason the member asked for it.
  def line(%{kind: "reference_check", title: title, grade: grade})
      when is_binary(title) and is_binary(grade),
      do: gettext("The review of “%{title}” is ready: %{grade}.", title: title, grade: grade)

  def line(%{kind: "reference_check", title: title}) when is_binary(title),
    do: gettext("The review of “%{title}” is ready.", title: title)

  def line(%{kind: "reference_check"}),
    do: gettext("An employment reference of yours has been reviewed.")

  # A kind added to the registry without a clause here still reads sensibly.
  def line(_item), do: gettext("Something new happened on your account.")

  # Handles, never display names: the house rule for anything the system says
  # about somebody, and the only name a reader can act on. `actor_param` is the
  # handle `Vutuv.Activity.actor_fields/1` puts on every actor-bearing item.
  defp handle(%{actor_param: param}) when is_binary(param), do: "@" <> param
  defp handle(%{username: username}) when is_binary(username), do: "@" <> username
  defp handle(_item), do: gettext("Somebody")
end

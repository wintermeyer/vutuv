defmodule VutuvWeb.RemoteActorCardHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.FediverseComponents
  import VutuvWeb.PostComponents

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.Handle
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteFollow
  alias Vutuv.RemoteHtml

  embed_templates("../templates/remote_actor_card/*")

  @doc """
  What the card calls the account: its display name, else the address it wears
  out there, else the address the reader tapped.

  Deliberately not `RemoteAccount.label/1`, whose last resort is the bare
  `actor_uri` — a card headed by a URL says nothing a reader was not already
  looking at, and the address they clicked says more.
  """
  def card_name(nil, address), do: "@" <> address

  def card_name(%RemoteAccount{} = account, address),
    do:
      RemoteAccount.display_name(account) || RemoteAccount.display_handle(account) ||
        card_name(nil, address)

  @doc "The `@user@host` line under the name, from the row where we have one."
  def card_handle(nil, address), do: "@" <> address

  def card_handle(%RemoteAccount{} = account, address),
    do: RemoteAccount.display_handle(account) || card_handle(nil, address)

  @doc """
  The monogram, from the same source every other remote-account surface uses
  (`remote_initials/1`) so one account is not "T" on its page and "@" here — the
  account's label starts with the `@` of its address whenever it has no display
  name, and `name_initials/1` would take that as the initial.

  For an address that resolved to nobody there is no row, so the handle the
  reader typed is all there is.
  """
  def card_initials(nil, address),
    do: address |> String.split("@") |> List.first() |> name_initials()

  def card_initials(%RemoteAccount{} = account, _address), do: remote_initials(account)

  @doc """
  Where "View the original" goes: the canonical actor id once we hold the row,
  and otherwise the same `https://host/@user` the mention's own `href` carries
  (`Vutuv.Fediverse.Handle.web_profile_url/2` owns that spelling), so the card
  can never send a reader somewhere the link would not have.
  """
  def origin_url(%RemoteAccount{actor_uri: uri}, _address), do: uri

  def origin_url(nil, address) do
    case RemoteFollow.parse_address(address) do
      {:ok, {user, host}} -> Handle.web_profile_url(user, host)
      _unparsable -> nil
    end
  end

  @doc """
  The destination, written the way a reader checks a link before following it —
  scheme, `www.` and trailing slash dropped, and nothing cut, because the card
  gives it a line of its own and CSS ends it where the card ends.

  A pass-through to `Vutuv.RemoteHtml.display_form/1` since the 40-character cap
  went, and kept for its name: this is the one control that takes a reader off
  the site, and the next thing anybody wants to do to that address (grey out the
  path, say) belongs here rather than in the template. Why the address is on the
  card at all is in the template comment beside it.
  """
  def origin_address(url) when is_binary(url), do: RemoteHtml.display_form(url)

  @doc """
  The colours the one state-carrying follow button wears, as a modifier rather
  than the pill's utility string (`follow_state_class/1`).

  A pill is a label and only needs a resting colour; this control is also the
  way *out* of the state it names, so each variant needs a hover half that turns
  it into the refusal it is about to become. That pairing lives in
  `components.css` beside the button, where a hover state belongs, instead of as
  twelve utilities here — and it keeps the vocabulary: the same three states the
  pill knows, in the same three colours.
  """
  def state_btn_modifier(follow), do: "actor-card__state-btn--#{Follow.display_state(follow)}"

  @doc """
  What the follow button asks before it acts, on a screen that cannot hover.

  The hover swap is the desktop's confirmation step — the button says "Following"
  and only turns into "Unfollow" once the pointer is on it, so the act is never
  what a stray click lands on. A phone has no such moment, and the two mistakes
  are not the same size: an unfollow can be undone with one press, while a
  withdrawn request has to be approved by hand on the other side all over again
  and may take days or never come back.

  So the wording is the act, phrased as the question the second press answers.
  It rides along as an attribute because `mention_card.js` must not write
  sentences: the card's words are the server's, in the reader's language.
  """
  def confirm_label(follow) do
    case Follow.display_state(follow) do
      :moved -> gettext("Really remove?")
      :accepted -> gettext("Really unfollow?")
      :requested -> gettext("Really withdraw?")
    end
  end
end

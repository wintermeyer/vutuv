defprotocol Vutuv.Identity do
  @moduledoc """
  The one answer to "who is speaking" for the two identity kinds vutuv has:
  a member (`Vutuv.Accounts.User`) and an organization page
  (`Vutuv.Organizations.Organization`) — issue #1416.

  Since the organization milestone (#1333-#1336) most shared surfaces carry a
  nullable `user_id | organization_id` pair and decide per call site which side
  speaks. This protocol is the display/dispatch half of that seam: name, path,
  image, PubSub topic, ActivityPub type and the doc/JSON reference all live
  here, so a surface asks the identity instead of pattern-matching the pair
  again. The query half is `Vutuv.Identity.Query`. Should a third actor kind
  ever arrive, it implements this protocol instead of being excavated into
  every call site.

  Deliberately dispatching on structs (loud `Protocol.UndefinedError` for
  anything else): the milestone's silent failures all came from code that
  answered quietly for the kind it did not know.
  """

  @doc "The identity's kind: `:user` or `:organization`."
  def kind(identity)

  @doc "The identity's id (UUID v7)."
  def id(identity)

  @doc """
  The visible name: a member's full name (honorifics included), a page's name.
  """
  def display_name(identity)

  @doc """
  The `@`-less handle, or nil: a member always has one, a page only once it
  claimed its opt-in root handle.
  """
  def handle(identity)

  @doc """
  The root-relative profile/page path: `/<handle>` for a member,
  `Vutuv.Organizations.canonical_path/1` for a page (which prefers the root
  handle over `/organizations/<slug>`).
  """
  def path(identity)

  @doc """
  The stored image token (`users.avatar` | `organizations.logo`), or nil.
  Rendering stays with `<.avatar>` / `<.organization_logo>` — the two kinds
  draw different fallback tiles on purpose.
  """
  def image(identity)

  @doc """
  Whether the identity is hidden from the anonymous public: a member who is
  unconfirmed or moderation-hidden (`Vutuv.Moderation.profile_visible_to?/2`
  with a nil viewer), a page that is not publicly visible
  (`Vutuv.Organizations.public_visible?/1`).
  """
  def hidden?(identity)

  @doc ~S|The identity's PubSub topic: `"user:<id>"` / `"organization:<id>"`.|
  def topic(identity)

  @doc ~S|The ActivityPub actor type: `"Person"` / `"Organization"`.|
  def ap_type(identity)

  @doc """
  The doc/JSON reference map naming the identity: `name` plus the member's
  `username` or the page's `slug`, and the absolute `url` of `path/1`. The one
  shape behind the API, the post JSON and the agent docs (it used to exist
  three times, each slightly different).
  """
  def ref(identity)
end

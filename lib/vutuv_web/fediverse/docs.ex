defmodule VutuvWeb.Fediverse.Docs do
  @moduledoc """
  The ActivityPub JSON documents for follow-only federation: the actor (a
  member's machine-readable identity, publishing the key deliveries are
  verified against), the Note a public post becomes, and the activity
  envelopes (Create/Update/Delete, plus the Accept a Follow is answered
  with). Lives in the web layer because everything here is URL building —
  like `VutuvWeb.AgentDocs`, which is the same idea for agents instead of
  Fediverse servers.

  URL scheme (all under the member, so nothing new burns a root slug):

      /:username/actor                       the actor document (id)
      /:username/actor/inbox                 POST target for Follow/Undo
      /:username/actor/followers             count-only collection
      /:username/actor/following             count-only collection (issue #1160)
      /:username/actor/outbox                count-only collection
      /:username/actor/collections/featured  the pinned post (issue #1110)

  The one exception is the installation-wide `endpoints.sharedInbox` (issue
  #1073), which belongs to nobody in particular and therefore lives under
  `/system/` — see `shared_inbox_url/0`.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.Actor
  alias Vutuv.Mentions
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostRemoteReply
  alias Vutuv.Posts.PostReply
  alias Vutuv.Posts.PostReview
  alias Vutuv.ReviewCover
  alias Vutuv.Tags.Tag
  alias VutuvWeb.PostComponents
  alias VutuvWeb.UserHelpers

  @public "https://www.w3.org/ns/activitystreams#Public"

  # Everything note/2 reads off a post. Kept here, beside the builder that needs
  # it, because two call sites load it (the delivery queue and the permalink's
  # ActivityPub rendering) and a field added to the Note must not silently render
  # as `NotLoaded` at one of them.
  @note_preloads [
    :images,
    :review,
    :remote_reply_ref,
    :tags,
    {:post_hashtags, :tag},
    # Both kinds of parent author (issue #1336), or an answer to a page's post
    # would render with no `inReplyTo` — see `parent_author/1`.
    {:reply_ref, [:parent_author, :parent_organization]}
  ]

  @doc "The associations `note/2` needs loaded on a post."
  def note_preloads, do: @note_preloads

  # A topic's actor lives on the tag host, and its id is the slug itself
  # (issue #1330). It has to be **that** host: Mastodon confirms an account by
  # re-resolving `preferredUsername@<host of the actor id>`, so an id on the
  # apex would advertise `hund@tags.<host>` and canonicalise to `hund@<host>` —
  # back into the member handle namespace, which is the collision the separate
  # host exists to prevent.
  def actor_url(%Tag{slug: slug}), do: "#{tag_base()}/#{slug}"

  def actor_url(%Organization{slug: slug}), do: "#{base()}/organizations/#{slug}/actor"
  def actor_url(user), do: "#{base()}/#{user.username}/actor"
  def key_id(user), do: actor_url(user) <> "#main-key"
  # A page's post lives under its slug, matching `Vutuv.Posts.path/1` — the
  # permalink is what a federated Note is identified BY, so the two spellings
  # must not drift.
  def note_url(%Organization{slug: slug}, post_id),
    do: "#{base()}/organizations/#{slug}/posts/#{post_id}"

  def note_url(user, post_id), do: "#{base()}/#{user.username}/posts/#{post_id}"

  @doc """
  The one inbox the whole installation offers (issue #1073), advertised as
  `endpoints.sharedInbox` in every actor document so a server with many
  followers here delivers a broadcast **once** instead of once per member — the
  efficiency we already take advantage of when we deliver outward.

  It is the only Fediverse URL that does not hang off a member, so it lives
  under `/system/` rather than at a root word: profiles own the URL root, and a
  new root segment would permanently burn a word a member could otherwise claim
  as a handle. Nothing is lost by the odd-looking path — remote servers only
  ever read it out of the actor document.
  """
  def shared_inbox_url, do: "#{base()}/system/inbox"

  @doc """
  The `featured` collection: the member's pinned post (issue #1110), which is
  how Mastodon and friends show a pinned post at the top of the profile they
  render. The path is the one those servers already expect.
  """
  def featured_url(user), do: actor_url(user) <> "/collections/featured"

  @doc "The `followers` collection, served count-only."
  def followers_url(user), do: actor_url(user) <> "/followers"

  @doc "The `outbox` collection, served count-only."
  def outbox_url(user), do: actor_url(user) <> "/outbox"

  @doc """
  The `following` collection (issue #1160): the accounts on other networks this
  member follows. Served count-only, exactly like `followers` — a remote server
  needs to know the actor follows *somebody* to render a sensible profile, and
  nobody needs the names.
  """
  def following_url(user), do: actor_url(user) <> "/following"

  @doc """
  A collection that publishes only how big it is: `followers`, `following` and
  `outbox` are all served this way, so the shape lives here with every other
  document rather than three times in the controller that answers them.
  """
  def count_collection(id, total) when is_binary(id) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id,
      "type" => "OrderedCollection",
      "totalItems" => total
    }
  end

  @doc """
  The member's Fediverse address without the leading `@`
  (`member@vutuv.de`) — the `acct:` form WebFinger answers under and remote
  servers resolve. The host is this installation's, so it is right on
  vutuv.de and on anybody else's vutuv.
  """
  # A topic's address lives on the tag host, which is its own WebFinger
  # authority (issue #1330) — that is what keeps `elixir` the topic and
  # `elixir` the member from wanting one address.
  def acct(%Tag{slug: slug}), do: "#{slug}@#{Vutuv.Fediverse.tag_host()}"

  def acct(user), do: "#{user.username}@#{VutuvWeb.Endpoint.host()}"

  @doc "The same address the way it is written for humans: `@member@vutuv.de`."
  def handle(user), do: "@" <> acct(user)

  @doc "The Person document WebFinger points at."
  def actor(user, %Actor{} = actor) do
    user
    |> base_actor(actor, user.inserted_at)
    |> Map.merge(%{
      "type" => Vutuv.Identity.ap_type(user),
      "preferredUsername" => user.username,
      "name" => UserHelpers.full_name(user),
      "summary" => summary(user),
      "url" => "#{base()}/#{user.username}",
      # Count-only like the followers collection, and for the same reason: who
      # a member reads is theirs to know (issue #1160). Always advertised, so a
      # remote server never has to guess whether this actor can follow back.
      "following" => following_url(user),
      # Where a remote server looks for the pinned post (issue #1110). Always
      # advertised, even with nothing pinned: the collection is then simply
      # empty, and an actor that only sometimes names the field would make the
      # profile a remote server renders depend on when it last fetched.
      "featured" => featured_url(user),
      "icon" => %{
        "type" => "Image",
        "mediaType" => "image/jpeg",
        "url" => "#{base()}/#{user.username}/avatar.jpg"
      }
    })
    |> put_also_known_as(user)
    |> put_moved_to(user)
  end

  @doc """
  A **topic's** actor document (issue #1330): AP type `Group`, which is what
  tells a remote server this is a thing to subscribe to rather than a person.

  Its own builder for the same reason the page's is: half of the member document
  has no meaning here. A topic has no `alsoKnownAs`/`movedTo` (nothing migrates
  a topic), no `featured` (nothing pins to it), and no name of its own beyond the
  one the catalogue gives it. What it keeps is the shared inbox and
  `manuallyApprovesFollowers: false`, both facts about this installation.

  The `url` deliberately points at the tag page on the **main** host: that is
  where a human reads the topic, and it is the one link a remote reader wants.
  """
  def tag_actor(%Tag{} = tag, %Actor{} = actor) do
    tag
    |> base_actor(actor, tag.inserted_at)
    |> Map.merge(%{
      "type" => "Group",
      "preferredUsername" => tag.slug,
      "name" => tag.name,
      "summary" => tag_summary(tag),
      "url" => "#{base()}/tags/#{tag.slug}"
    })
  end

  # The half of an actor document that says nothing about who the actor is: the
  # context, the collections derived from its own URL, this installation's
  # shared inbox (issue #1073 — the per-actor inbox is what every server
  # already knows and keeps working forever; this is the offer to deliver a
  # broadcast once for all of them), the approval flag and the key.
  #
  # It was written out three times, and the two lines that must never differ
  # between a member, a page and a topic — the `@context` list and the shared
  # inbox — were among the copies. The per-kind builders stay separate on
  # purpose, because half of the member document has no meaning for a page or a
  # topic; only this half is shared.
  defp base_actor(subject, %Actor{} = actor, published_at) do
    actor_url = actor_url(subject)

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1"
      ],
      "id" => actor_url,
      "inbox" => actor_url <> "/inbox",
      "outbox" => outbox_url(subject),
      "followers" => followers_url(subject),
      "endpoints" => %{"sharedInbox" => shared_inbox_url()},
      "manuallyApprovesFollowers" => false,
      "published" => iso8601(published_at),
      "publicKey" => %{
        "id" => key_id(subject),
        "owner" => actor_url,
        "publicKeyPem" => actor.public_key_pem
      }
    }
  end

  # One sentence saying what following this address does, because a `Group`
  # actor with a bare topic name tells a stranger nothing about what will arrive
  # in their timeline.
  defp tag_summary(%Tag{name: name}) do
    escaped = name |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    "<p>" <>
      Gettext.gettext(
        VutuvWeb.Gettext,
        "Posts tagged %{tag}. Follow this address to receive them, wherever your account lives.",
        tag: escaped
      ) <> "</p>"
  end

  @doc """
  A **page's** actor document (issue #1334): AP type `Organization`, which is
  what tells a remote server to render it as an organisation rather than as a
  person.

  Its own builder rather than a widened `actor/2`, because half of the member
  document has no meaning here and silently emitting those fields as nil would
  be worse than leaving them out: no `alsoKnownAs`/`movedTo` (account migration
  is a person's decision about their own identity, issue #986), and no
  `featured` collection (a page pins nothing — `posts.pinned_post_id` hangs off
  a member).

  What it does keep is the shared inbox and `manuallyApprovesFollowers: false`,
  because both are facts about this installation rather than about who the actor
  is.
  """
  def organization_actor(%Organization{} = organization, %Actor{} = actor) do
    organization
    |> base_actor(actor, organization.inserted_at)
    |> Map.merge(%{
      "type" => Vutuv.Identity.ap_type(organization),
      # The page's claimed handle. Federating without one is not possible —
      # WebFinger's `subject` and this field both need an address — which is why
      # `Fediverse.federated?/1` refuses a page that has not claimed one.
      "preferredUsername" => organization.username,
      "name" => organization.name,
      "summary" => organization_summary(organization),
      "url" => "#{base()}/organizations/#{organization.slug}"
    })
    |> put_organization_icon(organization)
  end

  # A page's description is Markdown, and `summary` is HTML — the first cut put
  # the stored source straight on the wire, so a bio written with a link or a
  # list travelled as its own markup characters, unescaped and unwrapped. It
  # goes through the renderer the page itself uses (`<.markdown_prose>`), so
  # what a remote server shows is what a visitor here reads, and through the
  # same absolutizer the post bodies use, because a root-relative `/handle`
  # means nothing on another server. The member half already did this with its
  # headline (`summary/1`), plainer only because a headline is one line of text.
  defp organization_summary(%Organization{description: description})
       when description in [nil, ""],
       do: ""

  defp organization_summary(%Organization{description: description}) do
    description
    |> VutuvWeb.Markdown.render()
    |> Phoenix.HTML.safe_to_string()
    |> absolutize()
  end

  # The page's logo, which is the avatar a remote server shows beside its name.
  # Rendered only when there is one: the document is a promise to strangers, and
  # `/organizations/:slug/avatar.jpg` answers for a page with a logo and nothing
  # else, so naming it unconditionally would advertise a 404.
  defp put_organization_icon(doc, %Organization{logo: nil}), do: doc

  defp put_organization_icon(doc, %Organization{} = organization) do
    Map.put(doc, "icon", %{
      "type" => "Image",
      "mediaType" => "image/jpeg",
      "url" => "#{base()}/organizations/#{organization.slug}/avatar.jpg"
    })
  end

  # The accounts the member is migrating *from* (issue #986). Rendered only
  # when set: a remote server that moves followers here checks that its origin
  # account is one of these aliases, so an empty list must be absent, never an
  # empty array that reads as "claims nothing".
  defp put_also_known_as(doc, user) do
    case user.also_known_as do
      [_ | _] = aliases -> Map.put(doc, "alsoKnownAs", aliases)
      _ -> doc
    end
  end

  # The account the member redirected their followers *to* (issue #986, half 2).
  # Present only after a move: remote servers show a "moved to" notice and steer
  # follows to the target instead of this actor.
  defp put_moved_to(doc, %{moved_to: uri}) when is_binary(uri), do: Map.put(doc, "movedTo", uri)
  defp put_moved_to(doc, _user), do: doc

  @doc """
  Move: the redirect broadcast to every follower inbox (issue #986). Both
  `object` and `actor` are the member's own actor; `target` is the account they
  moved to. A compliant server re-points its follow to `target` once that
  account lists this actor in its `alsoKnownAs`.
  """
  def move_activity(user, target) do
    actor_url = actor_url(user)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => actor_url <> "#moves/" <> Vutuv.UUIDv7.generate(),
      "type" => "Move",
      "actor" => actor_url,
      "object" => actor_url,
      "target" => target,
      "to" => [actor_url <> "/followers"]
    }
  end

  @doc """
  Delete: the member's own actor is gone (issue #985). Broadcast to their
  follower inboxes when the account is deleted so remote servers purge the
  actor and the copies of its posts. Best effort — remote deletion is advisory
  by protocol, so this is a courtesy, never a guarantee.
  """
  def actor_delete_activity(user) do
    actor_url = actor_url(user)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => actor_url <> "#delete",
      "type" => "Delete",
      "actor" => actor_url,
      "object" => actor_url,
      "to" => [@public]
    }
  end

  @doc "Create(Note): a freshly published public post."
  def create_activity(%Post{} = post, user) do
    note = note(post, user)

    envelope(user, "Create", note["id"] <> "#create", note)
    |> Map.put("published", note["published"])
  end

  @doc "Update(Note): an edited public post (id unique per edit)."
  def update_activity(%Post{} = post, user) do
    note = note(post, user)
    stamp = post.updated_at |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

    envelope(user, "Update", note["id"] <> "#update-#{stamp}", note)
  end

  @doc "Delete(Tombstone): a removed post (or one whose audience closed)."
  def delete_activity(post_id, user), do: tombstone_activity(note_url(user, post_id), user)

  @doc """
  Delete(Tombstone) for an **explicit** Note id (issue #1102).

  A revocation names the id the receiving server actually stored, which is not
  always the one `note_url/2` builds today: that id carries the username, so
  after a rename (issue #1086) a Tombstone built from the current username
  matches nothing on the other end. `Vutuv.Fediverse` keeps the published id per
  delivery and passes it here.
  """
  def tombstone_activity(note_url, user) when is_binary(note_url) do
    envelope(user, "Delete", note_url <> "#delete", %{
      "id" => note_url,
      "type" => "Tombstone"
    })
  end

  @doc """
  Flag: a reply that came from another network was reported here, so the
  moderators of its home server hear about it (issue #1102). Mastodon files an
  incoming `Flag` as a report.

  `object` is a **list** — the shape those servers send and expect — naming the
  reported note and the account that wrote it. Nothing else travels: no content,
  no category, and above all not who reported it.

  The `content` line is a fixed English sentence rather than a `gettext/1` one on
  purpose. It is read by a stranger's moderation team, not by a vutuv member, so
  it must not depend on the reporter's browser language; and a fixed sentence
  cannot leak anything a member typed.
  """
  def flag_activity(user, object_uri, actor_uri) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => actor_url(user) <> "#flags/" <> Vutuv.UUIDv7.generate(),
      "type" => "Flag",
      "actor" => actor_url(user),
      "object" => [object_uri, actor_uri],
      "content" =>
        "Reported by a member of #{VutuvWeb.Endpoint.host()} as inappropriate. " <>
          "The copy stored there has been removed."
    }
  end

  @doc """
  Announce: `reposter` boosts `author`'s public Note to the reposter's own
  followers (issue #910). The object is a bare Note id — a URI string — which
  is why the reposted author must federate too: a non-federating author serves
  no Note at that URL, so a remote server could not render the boost.
  """
  def announce_activity(%Post{} = post, author, reposter) do
    envelope(reposter, "Announce", announce_id(post, author, reposter), note_url(author, post.id))
  end

  @doc """
  Undo(Announce): `reposter` takes their boost back. The wrapped Announce
  carries the same stable id the original Announce had, so a remote server can
  match and drop it.
  """
  def undo_announce_activity(%Post{} = post, author, reposter) do
    reposter_actor = actor_url(reposter)

    envelope(reposter, "Undo", announce_id(post, author, reposter) <> "#undo", %{
      "id" => announce_id(post, author, reposter),
      "type" => "Announce",
      "actor" => reposter_actor,
      "object" => note_url(author, post.id)
    })
  end

  # Stable per (reposted note, reposter), so the Undo references the same
  # Announce the repost sent.
  defp announce_id(%Post{id: post_id}, author, reposter),
    do: note_url(author, post_id) <> "#announce-" <> announcer_name(reposter)

  # Whoever is doing the announcing, named the way their own actor is: a member
  # and a page by their handle, a topic by its slug (issue #1330), which is the
  # tag actor's name.
  defp announcer_name(%Tag{slug: slug}), do: slug
  defp announcer_name(actor), do: actor.username

  @doc """
  The `featured` collection document (issue #1110): the member's pinned post
  as a full Note, so a remote server can render it without a second fetch —
  the shape Mastodon serves and expects. `posts` is a list (empty = nothing
  pinned, or a pin the anonymous public may not see), so the collection can
  grow past one entry without changing the document.
  """
  def featured_collection(user, posts) when is_list(posts) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => featured_url(user),
      "type" => "OrderedCollection",
      "totalItems" => length(posts),
      "orderedItems" => Enum.map(posts, &note(&1, user))
    }
  end

  @doc """
  Add(Note -> featured): the member pinned a post (issue #1110). Sent to the
  follower inboxes so a remote profile shows the pin without waiting for its
  next actor refresh; the collection itself stays the authority.
  """
  def add_featured_activity(%Post{id: post_id}, user), do: featured_activity("Add", post_id, user)

  @doc """
  Remove(Note -> featured): the pin was released or replaced. Takes the bare
  post id, because the row is often already gone (or replaced) by the time
  this is built.
  """
  def remove_featured_activity(post_id, user) when is_binary(post_id),
    do: featured_activity("Remove", post_id, user)

  # Both carry the Note's **id** rather than the object: the receiving server
  # already knows the post (it was delivered as a Create), and the collection
  # is what it re-reads when it wants the full thing.
  defp featured_activity(type, post_id, user) do
    note_url = note_url(user, post_id)

    user
    |> envelope(type, note_url <> "##{String.downcase(type)}-featured", note_url)
    |> Map.put("target", featured_url(user))
  end

  @doc """
  The id of the `Follow` a member sends, built from the id of the row that
  records it (issue #1160).

  Minted here beside `#main-key`, `#flags/` and `#accepts/` rather than in the
  context, so one module owns every fragment scheme our actor URLs carry — even
  though this is the one id that has to exist *before* its row is inserted,
  because the `Accept` that comes back finds the follow by this string.
  """
  def follow_activity_id(user, follow_id), do: actor_url(user) <> "#follows/" <> follow_id

  @doc """
  Follow: a member here asks to follow an account on another network (issue
  #1160).

  `activity_id` is minted by `Vutuv.Fediverse` from the stored follow row and
  is the join between the two halves of the handshake: the other server echoes
  it back inside its `Accept` or `Reject`, and that is how the answer finds the
  row it belongs to.

  Addressed to the target alone, never to the public collection: a follow
  request is a message to one account, not an announcement. That is also why it
  carries no `cc` to the member's own followers.
  """
  def follow_activity(user, target_actor_uri, activity_id) do
    user
    |> follow_object(target_actor_uri, activity_id)
    |> Map.put("@context", "https://www.w3.org/ns/activitystreams")
  end

  # The Follow itself, without the JSON-LD context: it is the top-level
  # document's job, and repeating it on a nested object is noise.
  defp follow_object(user, target_actor_uri, activity_id) do
    %{
      "id" => activity_id,
      "type" => "Follow",
      "actor" => actor_url(user),
      "object" => target_actor_uri,
      "to" => [target_actor_uri]
    }
  end

  @doc """
  Undo(Follow): the member unfollows again. The wrapped Follow repeats the id
  the original carried, so the remote server can match it and drop the
  relationship rather than guess from actor and object.
  """
  def undo_follow_activity(user, target_actor_uri, activity_id) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id <> "#undo",
      "type" => "Undo",
      "actor" => actor_url(user),
      "object" => follow_object(user, target_actor_uri, activity_id),
      "to" => [target_actor_uri]
    }
  end

  @doc """
  Like: a member here likes a post on another network.

  Addressed to the **author alone**, never to the public collection or to the
  member's own followers. A like is a message to the person who wrote the
  thing, and telling a member's followers what they liked would publish a
  reading habit nobody asked to publish. It also keeps a followers-only post's
  like from travelling anywhere the post itself did not.
  """
  def like_activity(user, author_actor_uri, object_uri) do
    user
    |> like_object(object_uri)
    |> Map.merge(%{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "to" => [author_actor_uri]
    })
  end

  @doc """
  Undo(Like): the member takes the like back. The wrapped `Like` repeats the id
  the original carried, so the other server drops that exact activity instead of
  guessing from actor and object.
  """
  def undo_like_activity(user, author_actor_uri, object_uri) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => like_activity_id(user, object_uri) <> "#undo",
      "type" => "Undo",
      "actor" => actor_url(user),
      "object" => like_object(user, object_uri),
      "to" => [author_actor_uri]
    }
  end

  # The Like itself, built once for both halves the way `follow_object/3` is:
  # the Undo has to wrap the very activity it withdraws, and two hand-written
  # copies of one document are two chances for them to drift apart. Without the
  # JSON-LD context and the addressing — those are the top-level document's job.
  defp like_object(user, object_uri) do
    %{
      "id" => like_activity_id(user, object_uri),
      "type" => "Like",
      "actor" => actor_url(user),
      "object" => object_uri
    }
  end

  # Stable per (member, liked note), like `announce_id/3` and unlike the
  # `Follow`'s: the `Undo` has to name the very activity it withdraws, and the
  # id must survive a like → unlike → like, which a minted-per-row one would
  # not. A `Like` is never echoed back at us (a `Follow`'s id returns inside an
  # `Accept`), so there is nothing for a column to join on either.
  defp like_activity_id(user, object_uri),
    do: actor_url(user) <> "#likes/" <> Base.url_encode64(object_uri, padding: false)

  # The id a member's `Announce` of one remote post carries (issue #1166).
  # Derived from the pair like `announce_id/3` and `like_activity_id/2`: stable,
  # so the `Undo` names the very activity it withdraws, and stable across a
  # repost → un-repost → repost, which a minted-per-row id would not be.
  defp announce_remote_id(user, object_uri),
    do: actor_url(user) <> "#announces/" <> Base.url_encode64(object_uri, padding: false)

  @doc """
  Announce: a member here shares a post from another network with their own
  followers.

  Public addressing, unlike the `Like` beside it: a boost **is** publishing, and
  it is meant to be seen — that is the whole act. The original author rides in
  `cc` so their server learns of the boost the way Mastodon's own does.
  """
  def announce_remote_activity(user, author_actor_uri, object_uri, audience \\ "public") do
    user
    |> envelope("Announce", announce_remote_id(user, object_uri), object_uri)
    |> cc_author(author_actor_uri)
    |> match_audience(user, audience)
  end

  @doc """
  Undo(Announce): the member takes the boost back. The wrapped `Announce`
  repeats the original's id so the other server drops that exact activity.
  """
  def undo_announce_remote_activity(user, author_actor_uri, object_uri, audience \\ "public") do
    id = announce_remote_id(user, object_uri)

    user
    |> envelope("Undo", id <> "#undo", announce_remote_object(user, id, object_uri))
    |> cc_author(author_actor_uri)
    |> match_audience(user, audience)
  end

  # A boost must never be louder than what it boosts. `envelope/4` addresses
  # everything public — right for a public original, wrong for an **unlisted**
  # one, which its author deliberately kept out of public timelines by putting
  # the public collection in `cc` rather than `to`. Announcing it with
  # `to: [Public]` would file the reshare as public on every receiving server
  # and put somebody else's quiet post into the very timelines they avoided.
  # So the unlisted shape is mirrored exactly: followers in `to`, the public
  # collection demoted to `cc`.
  defp match_audience(activity, user, "unlisted") do
    followers = actor_url(user) <> "/followers"

    activity
    |> Map.put("to", [followers])
    |> Map.update!("cc", fn cc -> [@public | Enum.reject(cc, &(&1 == followers))] end)
  end

  defp match_audience(activity, _user, _public), do: activity

  # The Announce itself, built once for both halves the way `like_object/2` and
  # `follow_object/3` are: the Undo has to wrap the very activity it withdraws,
  # and two hand-written copies of one document are two chances to drift apart.
  defp announce_remote_object(user, id, object_uri) do
    %{
      "id" => id,
      "type" => "Announce",
      "actor" => actor_url(user),
      "object" => object_uri
    }
  end

  # The original author rides in `cc` beside the member's own followers, so
  # their server learns of the boost the way Mastodon's own does.
  defp cc_author(activity, author_actor_uri),
    do: Map.update!(activity, "cc", &(&1 ++ [author_actor_uri]))

  @doc "Accept(Follow): the answer that seals a remote follow."
  def accept_activity(user, follow_object) do
    id = actor_url(user) <> "#accepts/" <> Vutuv.UUIDv7.generate()

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id,
      "type" => "Accept",
      "actor" => actor_url(user),
      "object" => follow_object
    }
  end

  @doc "The Note a public post federates as."
  def note(%Post{} = post, user) do
    remote = remote_target(post)
    hashtags = hashtags(post)

    %{
      "id" => note_url(user, post.id),
      "type" => "Note",
      "attributedTo" => actor_url(user),
      "content" => content_html(post, remote, hashtags),
      "published" => iso8601(post.inserted_at),
      "to" => [@public],
      "cc" => cc(user, remote),
      "url" => note_url(user, post.id)
    }
    |> put_content_map(post)
    |> put_in_reply_to(post, remote)
    |> put_tag(remote, hashtags)
    |> put_attachments(post)
  end

  # The author's declared language federates as AS2 `contentMap` (issue
  # #1488) — the field Mastodon reads a Note's language from, and without
  # which the post is DROPPED from the public timelines of every reader with
  # a language filter set. NULL (legacy/undeclared) emits no key at all:
  # never a fabricated tag.
  defp put_content_map(note, %Post{language: language}) when is_binary(language),
    do: Map.put(note, "contentMap", %{language => note["content"]})

  defp put_content_map(note, _post), do: note

  # The reply from another network this post answers, when it answers one
  # (issue #1070). An un-preloaded association is a truthy `NotLoaded`, so it is
  # matched away explicitly rather than treated as "no target".
  defp remote_target(%Post{remote_reply_ref: %PostRemoteReply{} = ref}), do: ref
  defp remote_target(%Post{}), do: nil

  # A public answer is addressed like any other public post, plus the person it
  # answers. Naming them in `cc` (rather than `to`) is what Mastodon does for a
  # public reply: the post stays public, and the mentioned actor is delivered to
  # directly so it lands in their notifications.
  defp cc(user, nil), do: [actor_url(user) <> "/followers"]

  defp cc(user, %PostRemoteReply{actor_uri: actor_uri}),
    do: [actor_url(user) <> "/followers", actor_uri]

  # The `Mention` tag is what makes the remote server notify the person answered
  # and thread the reply under theirs.
  #
  # It is built from the **stored** actor URI, never from parsing the member's
  # typed text. Parsing would let anyone put `@someone@anywhere` in a post body
  # and have vutuv mint a verified-looking Mention at an actor nobody ever
  # checked, which is mention spam with our signature on it.
  #
  # It shares the array with the post's hashtags (issue #1421), so both are
  # written here rather than each overwriting the other's key.
  defp put_tag(note, remote, hashtags) do
    case mention_tag(remote) ++ Enum.map(hashtags, &hashtag_tag/1) do
      [] -> note
      tags -> Map.put(note, "tag", tags)
    end
  end

  defp mention_tag(nil), do: []

  defp mention_tag(%PostRemoteReply{} = ref) do
    [
      %{
        "type" => "Mention",
        "href" => ref.actor_uri,
        "name" => mention_handle(ref)
      }
    ]
  end

  defp hashtag_tag(%{name: name, href: href}),
    do: %{"type" => "Hashtag", "href" => href, "name" => name}

  # Every tag this post carries, in the shape a remote server can index it
  # (issue #1421). Two sources, and the difference between them matters only for
  # the closing line below: a `#hashtag` is already written in the body, the
  # composer's chips are not. Deduplicated by tag with the in-body spelling
  # winning, so a tag that is both is announced once and printed once.
  defp hashtags(%Post{} = post) do
    written = written_hashtags(post)

    in_body = for %{tag: %Tag{} = tag} <- loaded(post.post_hashtags), do: {tag, true}
    chips = for %Tag{} = tag <- loaded(post.tags), do: {tag, written?(tag, written)}

    (in_body ++ chips)
    |> Enum.uniq_by(fn {tag, _in_body?} -> tag.id end)
    |> Enum.flat_map(&hashtag/1)
  end

  # Whether the body already writes this tag out as a `#hashtag`, which the
  # `post_hashtags` rows alone cannot answer: `Vutuv.Posts.put_body_hashtags/2`
  # deliberately skips a hashtag the composer's field already filed, so a tag
  # that is *both* a chip and written in the sentence has a `post_tags` row and
  # no `post_hashtags` row at all. Reading the body settles it, and both of the
  # keys a hashtag resolves by (`Tag.find_by_value/1`: the name and the slug)
  # are checked, so a `#elixir` in the text covers the chip named `Elixir`.
  defp written_hashtags(%Post{body: body}) do
    body |> to_string() |> Mentions.hashtags() |> Enum.map(&String.downcase/1) |> MapSet.new()
  end

  defp written?(%Tag{name: name, slug: slug}, written) do
    MapSet.member?(written, String.downcase(to_string(name))) or
      MapSet.member?(written, String.downcase(to_string(slug)))
  end

  defp hashtag({%Tag{} = tag, in_body?}) do
    case hashtag_name(tag.name) do
      nil -> []
      name -> [%{name: "#" <> name, href: "#{base()}/tags/#{tag.slug}", in_body?: in_body?}]
    end
  end

  # Mastodon's charset for a hashtag is alphanumerics, `_` and a couple of
  # Unicode separators; everything else is stripped from the name it stores
  # (`HASHTAG_INVALID_CHARS_RE`). A hyphen is **not** in it, which rules out the
  # slug as the source: `machine-learning` would arrive over there as the tag
  # "machine" with loose text after it. The display name is the source instead,
  # with its separators removed and its casing kept, which is also what makes a
  # multi-word tag readable aloud: `Machine Learning` becomes `#MachineLearning`.
  # A name that has nothing left afterwards (a punctuation-only legacy tag) is
  # dropped rather than sent as a bare `#`.
  defp hashtag_name(name) when is_binary(name) do
    case String.replace(name, ~r/[^\p{L}\p{N}_]/u, "") do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp hashtag_name(_), do: nil

  # A `Post` handed over by a caller that forgot the preload must not crash the
  # delivery: no tags is the safe reading, and `note_preloads/0` is what keeps
  # the real paths honest.
  defp loaded(%Ecto.Association.NotLoaded{}), do: []
  defp loaded(list) when is_list(list), do: list
  defp loaded(_), do: []

  # How the answered account is written: the `@user@host` captured with the note.
  # Falls back to the bare host when the remote document carried no
  # `preferredUsername` (the same fallback `Vutuv.Fediverse.Note` makes).
  defp mention_handle(%PostRemoteReply{handle: handle}) when is_binary(handle) and handle != "",
    do: handle

  defp mention_handle(%PostRemoteReply{actor_uri: actor_uri}) do
    case URI.parse(actor_uri) do
      %URI{host: host} when is_binary(host) and host != "" -> "@" <> host
      _ -> actor_uri
    end
  end

  defp envelope(user, type, id, object) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id,
      "type" => type,
      "actor" => actor_url(user),
      "to" => [@public],
      "cc" => [actor_url(user) <> "/followers"],
      "object" => object
    }
  end

  # The same rendering members see, with every relative link/image made
  # absolute (remote servers render this HTML on their own domain). A review
  # sidecar is rendered INTO the content: the Note is one more rendering of
  # the post (like the agent docs), so a Mastodon reader gets the reviewed
  # work's facts even though remote software knows nothing of review cards.
  defp content_html(post, remote, hashtags) do
    body_html =
      post.body
      |> VutuvWeb.Markdown.render_post(images(post))
      |> Phoenix.HTML.safe_to_string()

    (mention_html(remote) <>
       body_html <> PostComponents.review_content_html(post) <> hashtag_line(hashtags))
    |> absolutize()
  end

  # The chips as a closing line of `#hashtags`, added **here, on the wire, only**
  # (issue #1421) — the same seam `mention_html/1` above uses, and for the same
  # reason: on vutuv these are chips under the post, and nobody's stored body
  # grows a line it was not written with. Only the tags the body does not
  # already name, or the post would print them twice.
  #
  # The `tag` array beside it is what a server *indexes*; this line is what a
  # reader *sees*, and the two are not interchangeable. Mastodon's spec
  # describes `Hashtag` as a Link subtype whose name carries the `#hashtag`
  # microsyntax and promises nothing about a tag that appears only in the array,
  # while a server that simply renders `content` shows none of them.
  defp hashtag_line(hashtags) do
    case Enum.reject(hashtags, & &1.in_body?) do
      [] ->
        ""

      appended ->
        "<p>" <> Enum.map_join(appended, " ", &hashtag_link/1) <> "</p>"
    end
  end

  defp hashtag_link(%{name: name, href: href}) do
    ~s(<a href="#{escape(href)}" class="hashtag" rel="tag">#{escape(name)}</a>)
  end

  defp escape(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # The answered account, written into the outgoing HTML the way these networks
  # write a reply: a leading linked `@user@host`.
  #
  # It is added **here, on the wire, only** — the member's stored body does not
  # carry it. On vutuv the answer shows a "Replying to" line instead, so a member
  # who has never heard of Mastodon does not have to type a handle in a foreign
  # format, and their post does not read like a foreign one. The handle is remote
  # supplied, so it is escaped.
  defp mention_html(nil), do: ""

  defp mention_html(%PostRemoteReply{} = ref) do
    handle =
      ref |> mention_handle() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    href = ref.actor_uri |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    ~s(<p><span class="h-card"><a href="#{href}" class="u-url mention">#{handle}</a></span></p>)
  end

  # Remote servers are anonymous viewers: only AI-released images may render
  # inline (released_images/1 also handles an un-preloaded association).
  defp images(post) do
    Posts.released_images(post)
  end

  # Root-relative src/href (post images, in-app links) must be absolute for a
  # remote server. A protocol-relative (`//host`) URL already resolves on its
  # own, so the negative lookahead leaves it alone instead of corrupting it
  # into `#{base()}//host` (the same guard as `VutuvWeb.Feeds.absolutize_urls/1`).
  defp absolutize(html) do
    VutuvWeb.Markdown.absolutize_html(html, base())
  end

  # An answer to a reply from another network points at **that** note (issue
  # #1070), not at the vutuv post underneath: the remote note already carries its
  # own `inReplyTo` back to our post, so this is what puts the answer in the right
  # place in the conversation on the other server. The URI is the durable copy
  # from the sidecar, so it still resolves after the cached note is collected.
  defp put_in_reply_to(note, _post, %PostRemoteReply{in_reply_to_uri: uri}),
    do: Map.put(note, "inReplyTo", uri)

  # Otherwise inReplyTo only when the parent's author federates too — a
  # non-federating author serves no Note at that id, and remote servers could
  # drop the post over an id that does not resolve.
  defp put_in_reply_to(note, post, nil) do
    case reply_parent(post) do
      nil -> note
      {parent_author, parent_id} -> Map.put(note, "inReplyTo", note_url(parent_author, parent_id))
    end
  end

  defp reply_parent(%Post{reply_ref: %Ecto.Association.NotLoaded{}}), do: nil
  defp reply_parent(%Post{reply_ref: nil}), do: nil

  defp reply_parent(%Post{reply_ref: reply_ref}) do
    with author when not is_nil(author) <- parent_author(reply_ref),
         true <- Vutuv.Fediverse.federated?(author),
         false <- Vutuv.Posts.restricted?(%Post{id: reply_ref.parent_post_id}) do
      {author, reply_ref.parent_post_id}
    else
      _ -> nil
    end
  end

  # Either kind of parent author (issue #1336): a member may answer a post
  # published in a page's name, and `federated?/1` and `note_url/2` both already
  # speak page as well as member. Matching `%User{}` alone left such an answer
  # with no `inReplyTo` at all, so it travelled as a standalone post and appeared
  # on the other server beside the conversation instead of inside it.
  defp parent_author(%PostReply{parent_author: %User{} = author}), do: author

  defp parent_author(%PostReply{parent_organization: %Organization{} = page}), do: page

  defp parent_author(%PostReply{}), do: nil

  # Public posts only federate, and a public post's images are publicly
  # servable through the authorizing proxy — so their URLs can ride along.
  # A released review cover rides along as an attachment too — a public
  # post's cover is publicly servable through the authorizing proxy.
  defp put_attachments(note, post) do
    attachments =
      Enum.map(images(post), fn image ->
        %{
          "type" => "Document",
          "mediaType" => "image/avif",
          "url" => base() <> PostImage.url(image, "large")
        }
      end) ++ cover_attachments(post)

    case attachments do
      [] -> note
      attachments -> Map.put(note, "attachment", attachments)
    end
  end

  defp cover_attachments(%Post{review: %PostReview{} = review}) do
    if PostReview.cover_ready?(review) do
      [
        %{
          "type" => "Document",
          "mediaType" => "image/avif",
          "name" => review.title,
          "url" => base() <> ReviewCover.url(review)
        }
      ]
    else
      []
    end
  end

  defp cover_attachments(%Post{}), do: []

  defp summary(user) do
    case user.headline do
      nil ->
        ""

      "" ->
        ""

      headline ->
        "<p>" <>
          (headline |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()) <> "</p>"
    end
  end

  defp iso8601(%NaiveDateTime{} = at),
    do: at |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601() |> Kernel.<>("Z")

  defp base, do: String.trim_trailing(VutuvWeb.Endpoint.url(), "/")

  # The same scheme and port as the main host, with the tag host in place of it,
  # so a dev server on :4000 and production both build a reachable URL.
  defp tag_base do
    %URI{URI.parse(base()) | host: Vutuv.Fediverse.tag_host()} |> URI.to_string()
  end
end

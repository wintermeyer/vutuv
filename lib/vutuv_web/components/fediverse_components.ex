defmodule VutuvWeb.FediverseComponents do
  @moduledoc """
  What the two pages that offer a follow out there have in common: the
  address box, the panel that explains a refusal, the wording of every
  `{:error, reason}` the context can answer with, and the follow-state pill.

  `VutuvWeb.FediverseFollowingLive` (`/settings/fediverse/following`) and
  `VutuvWeb.FediverseAccountLive` (`/system/fediverse/account/:id`, issue #1162)
  arrive at the same act from opposite ends — one starts from an address, the
  other from an account already in front of the reader — but from the moment
  the member presses Follow they are the same flow against the same context
  function, so they must not describe it differently.

  `Vutuv.Fediverse.follow_refusal/1` is the data half of that (which of the four
  situations the member is in); this is the half that says it in words. Keeping
  them apart would have been the same mistake one layer up: the atom shared,
  the sentence copied.

  Sibling of `VutuvWeb.BrowseTable`, which does the same job for the two
  relationship tables.

  `follow_us_from_elsewhere/1` faces the other way — it is what a visitor who is
  already on Mastodon reads on a member's profile and on an organization page —
  but it lives here for the same reason: those two pages describe one act, and a
  member's address and a page's address are the same kind of thing.

  The `lookup_refusal_*` half at the bottom does the same job for the other act
  this subsystem offers a member — fetching one post by its address — which has
  likewise grown a second surface: the lookup page and, since a URL means
  nothing to a text search, the search box itself (issue #1211).
  """

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  import VutuvWeb.UI

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow

  attr(:id, :string,
    required: true,
    doc: "names the form, the input, the button and the error line (`<id>-form`, …)"
  )

  attr(:address, :string, required: true)
  attr(:error, :any, default: nil, doc: "the reason the last submit came back with, or nil")
  attr(:event, :string, required: true, doc: "the phx-submit event the host handles")
  attr(:submit, :string, required: true, doc: "what the button says")
  attr(:variant, :string, default: "primary")

  attr(:label_hidden, :boolean,
    default: false,
    doc: "the field label reads to assistive tech only, where the card heading already names it"
  )

  attr(:class, :string, default: nil)

  slot(:error_detail, doc: "where to go instead, appended to the message")

  @doc """
  The address box: an `@name@server` in, an act on that account out.

  One markup for both pages, because the parts that matter here are the parts
  that get fixed on one copy only — the phone-keyboard attributes, and the
  `aria-invalid` / `aria-describedby` pair that ties the refusal to the field.
  `phx-change="typing"` is shared too: typing again clears the last refusal, so
  the box is not still shouting about an address the member has since corrected.
  """
  def address_form(assigns) do
    ~H"""
    <form
      id={"#{@id}-form"}
      phx-submit={@event}
      phx-change="typing"
      class={["flex flex-wrap items-end gap-3", @class]}
    >
      <div class="min-w-56 grow">
        <label
          for={"#{@id}-address"}
          class={
            if @label_hidden,
              do: "sr-only",
              else: "block text-sm font-semibold text-slate-700 dark:text-slate-200"
          }
        >
          {gettext("Address of the account")}
        </label>
        <%!-- `inputmode="email"` for the @ and the dot on a phone keyboard's
              first layer, without the validation an `type="email"` would apply
              to a two-@ address. iOS honours autocorrect separately from
              spellcheck. --%>
        <input
          type="text"
          name="address"
          id={"#{@id}-address"}
          value={@address}
          inputmode="email"
          autocomplete="off"
          autocapitalize="none"
          autocorrect="off"
          spellcheck="false"
          placeholder="@name@server"
          aria-invalid={@error && "true"}
          aria-describedby={@error && "#{@id}-error"}
          class={input_class(@error != nil)}
        />
      </div>
      <.button type="submit" id={"#{@id}-submit"} variant={@variant} class="w-full sm:w-auto">
        {@submit}
      </.button>
    </form>

    <p
      :if={@error}
      id={"#{@id}-error"}
      role="alert"
      class="mt-2 text-sm font-medium text-red-700 dark:text-red-300"
    >
      {refusal_message(@error)}
      {render_slot(@error_detail)}
    </p>
    """
  end

  attr(:id, :string,
    required: true,
    doc: "the card's id; the handle's `<code>` takes `<id>-handle`, which the copy button targets"
  )

  attr(:handle, :string,
    default: nil,
    doc:
      "`@name@host`, from `VutuvWeb.Fediverse.Docs`; `nil` when the page already shows the address somewhere else and only the form belongs here (the tag page's header carries it)"
  )

  attr(:name, :string,
    required: true,
    doc: "who is being followed, as the sentence names them: a member's full name, a page's name"
  )

  attr(:action, :string,
    required: true,
    doc: "where the visitor's own address is posted (`RemoteFollowController`)"
  )

  @doc """
  **The two questions a visitor arriving from Mastodon has**: what is this
  account's address over there, and how do I follow it without leaving my own
  app. One markup for a member's profile and for an organization page, because
  the visitor is the same person asking the same thing and neither answer is
  about vutuv.

  The handle is a copy target — that is the action people come for — and the form
  below it resolves the visitor's **own** server's follow dialog and sends them
  there, so the follow is confirmed where their account lives. Deliberately a
  classic form post and not a `phx-submit`: the answer is a redirect to another
  server, and someone arriving from a network we know nothing about is exactly
  the visitor we cannot assume JavaScript for. Phoenix stamps the CSRF token; a
  LiveView render loads the session's CSRF state, so the token is valid from both
  page styles.

  The form's own ids stay `remote-follow-*` rather than deriving from `@id`: no
  page shows two of these, the redirect targets are written against them, and
  they are what the tests key on.

  Pass `handle={nil}` when the page already shows the address somewhere the
  reader can copy it; the component then renders no copy box rather than a
  second one. A page that wants a different arrangement altogether (the tag
  page, whose card is placed by whether the reader is signed in) composes
  `copy_field/1` and `remote_follow_form/1` itself.
  """
  def follow_us_from_elsewhere(assigns) do
    ~H"""
    <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
      {gettext(
        "Are you on Mastodon or another Fediverse app? Follow %{name} from there and new public posts arrive in your timeline. No vutuv account needed.",
        name: @name
      )}
    </p>

    <.copy_field :if={@handle} id={"#{@id}-handle"}>{@handle}</.copy_field>

    <.remote_follow_form action={@action} />
    """
  end

  attr(:action, :string,
    required: true,
    doc: "where the visitor's own address is posted (`RemoteFollowController`)"
  )

  @doc """
  The "type your own address and I will send you to your server's follow dialog"
  half of `follow_us_from_elsewhere/1`, on its own so a page can arrange the
  sentence and the address around it however it likes.

  Deliberately a classic form post and not a `phx-submit`: the answer is a
  redirect to another server, and someone arriving from a network we know
  nothing about is exactly the visitor we cannot assume JavaScript for.

  Its ids stay `remote-follow-*` rather than deriving from a caller id: no page
  shows two of these, the redirect targets are written against them, and they
  are what the tests key on.
  """
  def remote_follow_form(assigns) do
    ~H"""
    <.form for={%{}} action={@action} id="remote-follow-form" class="mt-4">
      <label
        for="remote-follow-address"
        class="block text-sm font-semibold text-slate-900 dark:text-white"
      >
        {gettext("Follow from your own server")}
      </label>
      <div class="mt-1.5 flex flex-col gap-2 sm:flex-row">
        <input
          type="text"
          id="remote-follow-address"
          name="address"
          inputmode="email"
          autocomplete="off"
          autocapitalize="none"
          spellcheck="false"
          placeholder={gettext("@you@example.social")}
          class={[input_class(), "sm:min-w-0 sm:flex-1"]}
        />
        <.button type="submit" id="remote-follow-submit" class="shrink-0">
          {gettext("Follow")}
        </.button>
      </div>
      <p class="mt-1.5 text-xs text-slate-600 dark:text-slate-400">
        {gettext(
          "Your address is used once, to send you to your own server's follow dialog. It is never stored here."
        )}
      </p>
    </.form>
    """
  end

  attr(:id, :string, required: true)
  attr(:reason, :atom, required: true, doc: "from `Vutuv.Fediverse.follow_refusal/1`")

  attr(:address, :string,
    default: nil,
    doc: "an address the member brought along, kept in view while they go and switch on"
  )

  attr(:class, :string, default: nil)

  @doc """
  Why this member cannot follow anybody out there, and the one thing that helps.

  No actor, no follow: the request is signed with the member's own key. Say
  that, and put the switch one click away, rather than bouncing them to a page
  that does not mention following. Which sentence, though, depends on why — a
  member the moderation freezer is holding has already flipped that switch, and
  telling them to flip it again, on a page that shows it on, is the worst place
  to be vague.
  """
  def follow_refusal_panel(assigns) do
    ~H"""
    <div
      id={@id}
      data-reason={@reason}
      class={[
        "rounded-lg bg-slate-50 p-4 text-sm leading-relaxed text-slate-700 ring-1 ring-slate-200",
        "dark:bg-slate-800/50 dark:text-slate-300 dark:ring-slate-700",
        @class
      ]}
    >
      <%= case @reason do %>
        <% :restricted -> %>
          <p>
            {gettext(
              "Your account is on hold at the moment, so nothing of yours goes out to other networks and you cannot follow anybody there. This lifts by itself once the hold ends."
            )}
          </p>
          <p class="mt-3">
            <.link navigate={~p"/moderation/cases"} id="moderation-cases-link" class={refusal_link()}>
              {gettext("Why is my account on hold?")} ›
            </.link>
          </p>
        <% :disabled -> %>
          <p>
            {gettext(
              "This vutuv does not exchange anything with other networks, so there is nothing to follow from here. That is an operator setting, not yours."
            )}
          </p>
        <% :moved -> %>
          <%!-- The one refusal a *federating* member can be in: they redirected
                their Fediverse followers to another account, so this one no
                longer acts out there. Without its own arm they would get a live
                Follow button and a "that did not work, try again" for a state
                that is permanent until they cancel the redirect. --%>
          <p>
            {gettext(
              "You redirected your Fediverse followers to another account, so this one no longer follows anybody out there."
            )}
          </p>
          <p class="mt-3">
            <.link navigate={~p"/settings/fediverse/move"} id="fediverse-move-link" class={refusal_link()}>
              {gettext("Your account move")} ›
            </.link>
          </p>
        <% _opted_out -> %>
          <p>
            {gettext(
              "To follow an account out there you need a Fediverse identity of your own: the request is signed in your name, so the other server knows who is asking."
            )}
          </p>
          <p :if={@address not in [nil, ""]} class="mt-3">
            {gettext("The address you brought along is kept here:")}
            <span class="font-semibold break-all">{@address}</span>
          </p>
          <p class="mt-3">
            <.link navigate={~p"/settings/fediverse"} id="enable-fediverse-link" class={refusal_link()}>
              {gettext("Take part in the Fediverse")} ›
            </.link>
          </p>
      <% end %>
    </div>
    """
  end

  defp refusal_link,
    do:
      "font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"

  @doc """
  A follow that has not been answered reads **"Requested"**, not "Following".
  An account that approves its followers by hand may take days or never answer,
  and showing it as settled would be a lie the member acts on.

  A third state since issue #1168: the account **moved**. The row is a husk —
  the member's subscription has already been re-pointed at the successor and is
  waiting for it to answer — so it says so rather than reading as a live follow
  of an address that no longer posts.
  """
  def follow_state_label(follow) do
    cond do
      Follow.moved?(follow) -> gettext("Moved")
      Follow.accepted?(follow) -> gettext("Following")
      true -> gettext("Requested")
    end
  end

  @doc "The pill's colours for that state: emerald once settled, calm slate while it waits."
  def follow_state_class(follow) do
    cond do
      Follow.moved?(follow) ->
        "bg-amber-50 text-amber-800 ring-amber-200 dark:bg-amber-900/30 dark:text-amber-200 dark:ring-amber-800"

      Follow.accepted?(follow) ->
        "bg-emerald-50 text-emerald-800 ring-emerald-200 dark:bg-emerald-900/30 dark:text-emerald-200 dark:ring-emerald-800"

      true ->
        "bg-slate-100 text-slate-700 ring-slate-200 dark:bg-slate-800 dark:text-slate-300 dark:ring-slate-700"
    end
  end

  @doc """
  A request nobody has answered is not something you unfollow — you take the
  request back. Two labels, because a member who reads "Unfollow" on a
  Requested row learns that the state badge does not mean anything.
  """
  def end_follow_label(follow) do
    cond do
      # A husk left by a move was never requested and is not being followed —
      # the row is a record of where the member's subscription came from, and
      # what they do to it is put it away.
      Follow.moved?(follow) -> gettext("Remove")
      Follow.accepted?(follow) -> gettext("Unfollow")
      true -> gettext("Cancel request")
    end
  end

  @doc """
  The sentence for one `{:error, reason}` from `Vutuv.Fediverse`.

  One table for both pages, because both speak to the same context function:
  a reason that got a precise sentence on one page and a shrugging "that did
  not work" on the other would be the same refusal explained twice, once badly.
  """
  def refusal_message(:invalid_address),
    do:
      gettext(
        "That does not look like an address on another network. They look like @name@server."
      )

  def refusal_message(:unreachable),
    do: gettext("That server did not answer. Check the address, and that the server is online.")

  def refusal_message(:no_actor),
    do: gettext("That server answered, but it has no account at that address to follow.")

  def refusal_message(:unreachable_actor),
    do: gettext("That account could not be loaded from its server. Try again in a little while.")

  def refusal_message(:instance_blocked),
    do: gettext("This vutuv does not exchange anything with that server.")

  # The address turned out to be on this very vutuv without naming a member —
  # one that does resolve is followed here on the spot instead of refused. The
  # caller adds the search hand-off as the way forward.
  def refusal_message(:local_account),
    do: gettext("That address is on this vutuv, but it names no member here.")

  # The member's very own address. The wording has to carry the whole answer:
  # there is no link or button that makes following yourself sensible.
  def refusal_message(:own_account),
    do: gettext("That is your own address. You cannot follow yourself.")

  # Deliberately without "it is in the list below": the error keeps the active
  # filter and the table is paged, so the row it points at is often genuinely
  # not below.
  def refusal_message(:already_following),
    do: gettext("You already follow that account.")

  # The one refusal the member can act on, so it never falls through to the
  # generic "check the address" line — the address was fine. Reachable although
  # both pages render the switch panel for a non-federating member, because
  # participation can end between mount and submit (a second tab, a freeze).
  def refusal_message(:not_federating),
    do:
      gettext(
        "You are not taking part in the Fediverse at the moment, so there is no identity to sign the request with. Open the Fediverse settings to switch it on."
      )

  def refusal_message(:follow_capped),
    do:
      gettext("You have sent a lot of follow requests in the last hour. Please try again later.")

  def refusal_message(:follow_limit),
    do:
      gettext("You are following the most accounts we allow (%{max}).",
        max: delimited_count(Fediverse.max_remote_follows())
      )

  def refusal_message(:moved),
    do:
      gettext(
        "You redirected your Fediverse followers to another account, so this account no longer acts out there."
      )

  def refusal_message(:fediverse_disabled),
    do: gettext("The Fediverse is switched off on this vutuv.")

  def refusal_message(_other),
    do: gettext("That did not work. Check the address and try again.")

  @doc """
  The sentence for one `{:error, reason}` from `Vutuv.Fediverse.look_up_post/2`.

  Its own table beside `refusal_message/1`, and one table for both places a post
  address can be pasted — the lookup page and the search box (issue #1211). The
  states a member is in are named once above and taken from there; what is wrong
  with **this URL** is only ever asked here, and the follow table's fallback
  would tell somebody to check an address they never typed.
  """
  def lookup_refusal_message(:invalid_post_url),
    do:
      gettext(
        "That does not look like a link to a post. Copy the address of the post itself, for example https://server/@name/12345."
      )

  def lookup_refusal_message(:local_url),
    do: gettext("That is a link on this vutuv, not on another network.")

  def lookup_refusal_message(:post_unreachable),
    do: gettext("That server did not answer. Check the address, and that the server is online.")

  def lookup_refusal_message(:not_a_post),
    do: gettext("There is no post to show at that address.")

  def lookup_refusal_message(:post_not_public),
    do:
      gettext(
        "Its author published this post to their followers alone, so vutuv does not keep a copy of it."
      )

  def lookup_refusal_message(:lookup_capped),
    do: gettext("You have looked a lot of posts up in the last hour. Please try again later.")

  def lookup_refusal_message(reason), do: refusal_message(reason)

  @doc """
  Why this member cannot look a post up at all, in words: the heading, the
  explanation and where to go instead (`{path, label}`, or `nil` when there is
  nowhere to go). The data half is `Vutuv.Fediverse.lookup_refusal/1`.

  Deliberately not `follow_refusal_panel/1`'s wording: that one explains why a
  **follow** cannot be signed, and telling somebody who pasted a post link that
  they need an identity "to follow an account out there" answers a question they
  did not ask. The switch behind it is the same one.

  Three functions rather than one panel, because the two pages that render it
  give it different weight: the lookup page puts a titled panel where the form
  would be, the search page appends two lines to a card that already has a
  heading.
  """
  def lookup_refusal_title(:not_federating),
    do: gettext("Turn on Fediverse participation to look up")

  def lookup_refusal_title(:moved), do: gettext("This account no longer acts out there")
  def lookup_refusal_title(_disabled), do: gettext("This vutuv stays to itself")

  @doc "The explanation under `lookup_refusal_title/1`."
  def lookup_refusal_text(:not_federating),
    do:
      gettext(
        "Fetching a post asks its server for it in your name, signed with your own key, so there is no such thing as an anonymous lookup here."
      )

  def lookup_refusal_text(:moved),
    do:
      gettext(
        "You redirected your Fediverse followers to another account, so nothing is fetched or sent from this one any more."
      )

  def lookup_refusal_text(_disabled),
    do:
      gettext(
        "This vutuv does not exchange anything with other networks. That is an operator setting, not yours."
      )

  @doc """
  Where a refused member can act on it, as `%{path:, label:}` — `nil` when
  nowhere. A map rather than a tuple because both call sites render it in HEEx,
  where a tuple costs an `elem(@refusal_link, 0)` and the next reader a trip
  back here to learn which element is the path.
  """
  def lookup_refusal_link(:not_federating),
    do: %{path: ~p"/settings/fediverse", label: gettext("Fediverse settings")}

  def lookup_refusal_link(:moved),
    do: %{path: ~p"/settings/fediverse/move", label: gettext("Your account move")}

  def lookup_refusal_link(_disabled), do: nil
end

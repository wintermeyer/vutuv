defmodule VutuvWeb.UsernameHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/username/*")

  @doc """
  The second line of the "nothing has changed yet" notice: which handle the
  member still holds, and what will actually make the rename happen.

  It names the **PIN** only when an emailed PIN is genuinely the only way in
  (`email_only?` — no passkey, no authenticator app, no code list). Saying "per
  PIN" to a member holding a passkey would send them looking for mail that is
  not coming, which is the same "the page tells you something untrue" failure
  this notice exists to fix; they get the factor-neutral wording and the card
  below shows their actual options.
  """
  def pending_notice_line(options, handle)

  def pending_notice_line(%{email_only?: true}, handle) do
    gettext(
      "You are still @%{handle}. The new name only takes effect once you confirm with the PIN below.",
      handle: handle
    )
  end

  def pending_notice_line(_options, handle) do
    gettext("You are still @%{handle}. The new name only takes effect once you confirm below.",
      handle: handle
    )
  end

  @doc """
  The confirmation card's opening line: why we are asking, and what will end the
  wait for THIS member.

  Every factor but one is typed into the code field (emailed PIN, authenticator
  app, one-time list code), so "enter a valid code below" is true for almost
  everybody. A **passkey** is the exception — it is a button, nothing is typed —
  so a member holding one is told about it rather than being pointed at a field
  they do not have to touch.
  """
  def confirm_intro_line(%{passkey?: true}) do
    gettext(
      "Your username is your public identity here. It changes only once you confirm with your passkey or a valid code below."
    )
  end

  def confirm_intro_line(_options) do
    gettext(
      "Your username is your public identity here. It changes only once you enter a valid code below."
    )
  end

  @doc """
  Labels the one confirmation-code field for whatever this member actually has.

  The field takes an emailed PIN, an authenticator-app code or a one-time list
  code interchangeably (`Vutuv.Accounts.check_confirmation_code/3`), so naming
  it "PIN" would send a member with an authenticator app hunting for mail that
  is not coming. It names their fastest option and the hint below it spells out
  the rest.
  """
  def code_field_label(%{totp?: true}), do: gettext("Code from your authenticator app")
  def code_field_label(%{list_codes?: true}), do: gettext("Code from your list")
  def code_field_label(_options), do: gettext("PIN")

  @doc """
  The muted line under the code field: where the PIN went once one has gone out,
  otherwise what the field accepts. It must never claim we emailed a PIN when we
  did not — a member with several addresses (or a passkey) is deliberately not
  mailed unasked, and telling them to check an inbox nothing was sent to is how
  a confirmation step turns into a support ticket.
  """
  def code_field_hint(options, pin_email)

  def code_field_hint(%{codes?: true}, email) when is_binary(email) do
    gettext("We sent a PIN to %{email}. Any of your other codes works here too.", email: email)
  end

  def code_field_hint(_options, email) when is_binary(email) do
    gettext("We sent a PIN to %{email}.", email: email)
  end

  def code_field_hint(%{codes?: true}, _pin_email) do
    gettext("Your authenticator app or one-time code list, or a PIN we email you.")
  end

  def code_field_hint(_options, _pin_email) do
    gettext("Ask for a PIN first, then enter it here.")
  end

  @doc """
  Whether the "email me a PIN" block belongs **above** the code field: true only
  when the member has nothing to type yet — no PIN in flight and no authenticator
  app or code list. Then fetching a code is genuinely the first step. Everyone
  else already has a code, so the sender drops below the form as the quiet
  "send it again".
  """
  def pin_sender_first?(options, pin_email)
  def pin_sender_first?(_options, email) when is_binary(email), do: false
  def pin_sender_first?(%{codes?: true}, _pin_email), do: false
  def pin_sender_first?(_options, _pin_email), do: true

  @doc """
  The "email me a PIN" block: the address picker (only when the member has more
  than one) and the send button. Rendered in one of two places by
  `pin_sender_first?/2`, so the markup lives here rather than twice in the
  template.

  The picker lists only the member's own addresses, and the controller checks
  the submitted one against that same list — without it, "where should we mail
  this?" would be a way to send a valid PIN to somebody else's inbox.
  """
  attr(:options, :map, required: true)
  attr(:pin_email, :string, default: nil)
  attr(:class, :string, default: nil)
  attr(:rest, :global)

  def pin_sender(assigns) do
    ~H"""
    <div class={@class} {@rest}>
      <.form
        :let={f}
        for={%{}}
        as={:username_pin}
        action={~p"/settings/username/pin"}
        method="post"
        id="username-pin-form"
        class="flex flex-col gap-3 sm:flex-row sm:items-end"
      >
        <div :if={length(@options.emails) > 1} class="min-w-0 flex-1">
          <label
            for="username_pin_email"
            class="block text-sm font-medium text-slate-900 dark:text-white"
          >
            {gettext("Send the PIN to")}
          </label>
          <%= select(f, :email, @options.emails,
            selected: @pin_email || hd(@options.emails),
            class: input_class()
          ) %>
        </div>
        <input
          :if={length(@options.emails) <= 1}
          type="hidden"
          name="username_pin[email]"
          value={List.first(@options.emails)}
        />

        <button
          type="submit"
          class="shrink-0 rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
        >
          {(@pin_email && gettext("Send a new PIN")) || gettext("Email me a PIN")}
        </button>
      </.form>

      <p
        :if={length(@options.emails) <= 1 && !@pin_email}
        class="mt-2 text-sm text-slate-600 dark:text-slate-400"
      >
        {gettext("The PIN goes to %{email}.", email: List.first(@options.emails))}
      </p>
    </div>
    """
  end
end

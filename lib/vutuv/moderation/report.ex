defmodule Vutuv.Moderation.Report do
  @moduledoc false

  use VutuvWeb, :model

  alias VutuvWeb.UserHelpers

  @copyright "copyright"
  @categories ~w(family bullying spam copyright other)
  # A private message is not published, so there is nothing for a rights holder
  # to have taken down. Written as the exception rather than as a second list,
  # so a category added above cannot silently skip the message form.
  @message_categories @categories -- [@copyright]
  # Job postings get a specific first category; "family"/"bullying" rarely apply.
  @job_categories ~w(misleading_job spam copyright other)
  # A profile picture or cover (issue #2012). Copyright is the point of the
  # type, and a picture can as easily be the family-friendliness or the
  # harassment complaint. Spam is left out deliberately: an advert as a profile
  # picture is a complaint about the account, and that report — which the spam
  # auto-defense counts towards freezing a whole profile — belongs on the
  # profile, not on one of its pictures.
  @image_categories ~w(family bullying copyright other)
  @max_note_length 2_000

  schema "moderation_reports" do
    field(:category, :string)
    field(:note, :string)
    field(:abusive?, :boolean, default: false)
    # What the form binds to. The stored half is the column below.
    field(:good_faith?, :boolean, virtual: true, default: false)

    # When the notifier declared that the use is licensed neither by the rights
    # holder nor by law. Stored since issue #2069, because the declaration is
    # part of what makes a notice a notice (DSA Art. 16(2)(d)) and was until
    # then validated and dropped — nothing on the case, in the queue or
    # anywhere else recorded that it had been made. The category cannot stand
    # in for it: the public form demands the same declaration for **every**
    # category (issue #2009), so "this is a copyright report" answers a
    # different question.
    #
    # A timestamp rather than a boolean, though it can only ever hold this
    # row's own `inserted_at`: the fact has exactly two states, made and not on
    # file, because the changeset refuses a report that needed the declaration
    # and did not carry one — there is no "declined". A nullable boolean would
    # spell those two states with three, and nothing would ever write the
    # third. Nil on a report filed before the column existed, and deliberately
    # not backfilled: it would be invented evidence.
    field(:good_faith_declared_at, :naive_datetime)

    belongs_to(:case, Vutuv.Moderation.Case)
    # Nullable since issue #2009: a rights holder without an account files
    # through `/system/report` and is identified by a confirmed address
    # instead. Exactly one of the two is set (a CHECK constraint, not a
    # convention).
    belongs_to(:reporter, Vutuv.Accounts.User)

    # The outside notifier. Stored in the clear, because an admin has to be
    # able to write back; shown to admins only, never to the owner of the
    # reported content.
    field(:reporter_email, :string)
    field(:reporter_name, :string)

    # The same address reduced to the mailbox it really is
    # (`canonical_email/1`). It carries the uniqueness, so a `+tag` cannot buy
    # a second notice about one piece of content, while the column above keeps
    # the spelling an admin has to reply to.
    field(:reporter_email_key, :string)

    # The receipt mail's confirmation link. Until it is followed the notice
    # counts for nothing (`effective?/1`): the case sits `flagged` in the admin
    # queue and nothing is hidden. Past the deadline it counts for nothing ever
    # again — a link that never dies is a takedown anybody can set off a year
    # later out of a forwarded mail.
    field(:confirmation_hash, :string)
    field(:confirmation_expires_at, :naive_datetime)
    field(:confirmed_at, :naive_datetime)

    # The language the notice was filed in. There is no member row to read one
    # from, and the outcome mail (issue #2011) is built inside whichever admin's
    # request settled the case, so without this a German photographer would be
    # answered in the ruling admin's language.
    field(:reporter_locale, :string)

    # The claim that makes "each reporter hears once" true, and the in-app
    # entry's timestamp — see `Vutuv.Moderation.Notifier.reporters_case_closed/1`.
    field(:outcome_notified_at, :naive_datetime)

    timestamps()
  end

  def categories, do: @categories

  @doc """
  The category for "this is not yours to publish". The one complaint that is a
  legal notice rather than a house-rule one, so several places downstream ask
  for it by name rather than by string.
  """
  def copyright_category, do: @copyright

  @doc "Whether this report — or this bare category string — is a copyright complaint."
  def copyright?(%__MODULE__{category: category}), do: copyright?(category)
  def copyright?(category), do: category == @copyright

  @doc """
  The note's character cap — the changeset's `validate_length` and the form's
  `maxlength` both read it, so they cannot disagree.
  """
  def max_note_length, do: @max_note_length

  @doc """
  Whether this report counts for anything yet.

  A member's report always does. An **outside** notice only does once its
  address has been confirmed — before that it is a stranger's unverified claim,
  and every tally that can hide content (the trust ladder, the profile-freeze
  count, the spam auto-defense) filters on this. Without it five unconfirmed
  submissions would freeze any profile, which is the abuse a public form buys
  if nobody says no.
  """
  def effective?(%__MODULE__{reporter_id: id}) when is_binary(id), do: true
  def effective?(%__MODULE__{confirmed_at: %NaiveDateTime{}}), do: true
  def effective?(%__MODULE__{}), do: false

  @doc """
  The same rule as a query scope, so the three places that count reports in SQL
  cannot spell it differently from `effective?/1`. A member's report has no
  `confirmed_at` and needs none; an outside notice must have one.
  """
  def effective(query) do
    from(r in query, where: not is_nil(r.reporter_id) or not is_nil(r.confirmed_at))
  end

  @doc """
  The reports on this case that still owe their reporter the decision notice
  (issue #2011): effective, not marked abusive, not told yet.

  Two of those three are decisions rather than bookkeeping. An **unconfirmed**
  notice is left out because nobody proved they can read that address: the
  receipt is the one mail it earns, and answering an unverified claim would both
  confirm to a stranger that the content exists and mail an address that never
  asked us for anything. An **abusive** report is left out because an admin has
  just ruled it a deliberate weapon — the notice exists so a good-faith reporter
  stops checking the URL, and a member marked abusive is already hearing about
  it through the strike ladder.
  """
  def awaiting_outcome(case_id) do
    from(r in effective(__MODULE__),
      where: r.case_id == ^case_id and is_nil(r.outcome_notified_at) and r.abusive? == false
    )
  end

  @doc "The report categories offered for a given content type (wire string)."
  def categories_for("job_posting"), do: @job_categories
  def categories_for("image"), do: @image_categories
  def categories_for("message"), do: @message_categories
  def categories_for(_type), do: @categories

  @doc """
  Builds a report changeset. `content_type` (the wire string) restricts the
  accepted categories to the ones that type actually offers, so a crafted POST
  can't slip an off-type category (e.g. `misleading_job` on a profile report)
  past the form — the same `categories_for/1` gate the form renders from.

  Every message is a whole sentence addressed to the reporter, because the
  report form has no per-field error slots and shows them as one banner. They
  are extracted for translation through
  `VutuvWeb.ErrorHelpers.__error_message_extraction_anchors__/0`.

  `full_notice?: true` demands the explanation and the good-faith declaration
  for **every** category rather than only for `copyright` — what the public
  form asks (see `outside_changeset/3`). It is an option here rather than a
  second pass at the call site so that "which report has to be complete" keeps
  one owner; stacking a second `validate_required(:note)` on top of this one
  gave a copyright notice its demand twice, in two different wordings, in a
  banner that joins every message into one line.
  """
  def changeset(report, params \\ %{}, content_type \\ nil, opts \\ []) do
    pick_one = "Please pick a category."

    report
    |> cast(params, [:category, :note, :good_faith?])
    |> update_change(:note, &String.trim/1)
    |> validate_required([:category], message: pick_one)
    |> validate_inclusion(:category, categories_for(content_type), message: pick_one)
    |> validate_length(:note, max: @max_note_length, message: "Your note is too long.")
    |> validate_full_notice(Keyword.get(opts, :full_notice?, false))
    |> record_good_faith()
    |> unique_constraint([:case_id, :reporter_id])
  end

  # The declaration as a stored fact rather than a passing validation
  # (issue #2069). Stamped whenever it was ticked, not only where it was
  # demanded, so the column answers one question — "was this declared?" — for
  # every report, however it was filed.
  defp record_good_faith(changeset) do
    if get_field(changeset, :good_faith?),
      do: put_change(changeset, :good_faith_declared_at, NaiveDateTime.utc_now(:second)),
      else: changeset
  end

  @doc """
  A report filed through the public form at `/system/report` by somebody who
  has no account here (issue #2009).

  Three things are stricter than for a member. Every category needs the written
  explanation and the good-faith declaration, not only `copyright`: a member is
  identified by their account and answerable through it, a stranger is
  answerable only through what they wrote and the address they confirmed. And
  the name and the address are required, because the notice is worth nothing to
  an admin without a way back to the person who sent it.
  """
  def outside_changeset(report, params, content_type) do
    report
    |> changeset(params, content_type, full_notice?: true)
    |> cast(params, [:reporter_name, :reporter_email])
    # Collapsed to ONE line where it is written, not where it is rendered. The
    # name is the only stranger-controlled string this app puts into running
    # text in a mail it signs, and a value carrying a line break wrote whole
    # sentences of its own above our copy and the real confirmation link. Doing
    # it here means no later surface has to remember — see
    # `VutuvWeb.UserHelpers.single_line/1` for why the rule is the effect.
    |> update_change(:reporter_name, &UserHelpers.single_line/1)
    |> update_change(:reporter_email, fn value -> value |> String.trim() |> String.downcase() end)
    |> validate_required([:reporter_name], message: "Please tell us your name.")
    |> validate_required([:reporter_email], message: "Please give us an email address.")
    |> validate_format(:reporter_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "That does not look like an email address."
    )
    # The RFC 5321 address cap, inside the varchar(255) column: an oversized
    # value must be a changeset error, never a raised Postgres 22001.
    |> validate_length(:reporter_email, max: 254, message: "That address is too long.")
    |> validate_length(:reporter_name, max: 255, message: "Your name is too long.")
    |> put_email_key()
    |> unique_constraint(:reporter_email,
      name: :moderation_reports_case_reporter_email_index,
      message: "You already reported this."
    )
    |> unique_constraint(:reporter_email,
      name: :moderation_reports_case_reporter_email_key_index,
      message: "You already reported this."
    )
  end

  defp put_email_key(changeset) do
    case get_change(changeset, :reporter_email) do
      nil -> changeset
      email -> put_change(changeset, :reporter_email_key, canonical_email(email))
    end
  end

  @doc """
  The mailbox an address really names, for counting rather than for writing to.

  Two spellings reach one inbox at practically every provider: a `+tag` suffix
  is stripped by all of them, and Gmail additionally ignores dots in the local
  part. Both were undercutting the two caps the public notice form leans on —
  the per-address rate limit and the one-notice-per-content unique index — so
  `victim+1@`, `victim+2@` and, at Gmail, `v.ictim@` each bought a fresh budget
  and a fresh row.

  Dots are folded **only** for Gmail, and that asymmetry is the point: it is
  documented behaviour there and nowhere else, so folding them everywhere would
  merge two different people at a provider that treats them as distinct. The
  result is never mailed to and never shown; `reporter_email` keeps the
  spelling an admin replies to.
  """
  def canonical_email(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() |> String.split("@", parts: 2) do
      [local, domain] -> strip_tag(local, domain) <> "@" <> domain
      _ -> email
    end
  end

  def canonical_email(other), do: other

  @gmail_domains ~w(gmail.com googlemail.com)

  defp strip_tag(local, domain) do
    local = local |> String.split("+", parts: 2) |> hd()
    if domain in @gmail_domains, do: String.replace(local, ".", ""), else: local
  end

  # A copyright complaint only means something as a complete notice: which work
  # it is and where the original can be seen (the note), plus the reporter's
  # declaration that the use really is unauthorized. Both are checked here, at
  # the one place every report passes, so no route can file half a notice and
  # still get the freeze and the admin queue that the category buys.
  #
  # `always?` widens the same demand to every category, which is what the
  # public form asks of a stranger (issue #2009).
  defp validate_full_notice(changeset, always?) do
    copyright? = copyright?(get_field(changeset, :category))

    if always? or copyright? do
      changeset
      |> validate_required([:note], message: missing_note_message(copyright?))
      |> validate_good_faith()
    else
      changeset
    end
  end

  defp missing_note_message(true),
    do: "Please tell us which work it is and where the original can be seen."

  defp missing_note_message(false),
    do: "Please tell us what is wrong with this content, in your own words."

  # Spelled out rather than `validate_acceptance/3`, which only fires when the
  # parameter is present — and an unticked checkbox sends nothing at all.
  defp validate_good_faith(changeset) do
    if get_field(changeset, :good_faith?) do
      changeset
    else
      add_error(
        changeset,
        :good_faith?,
        "Please confirm that you are making this claim in good faith."
      )
    end
  end
end

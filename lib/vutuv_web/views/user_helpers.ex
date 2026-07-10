defmodule VutuvWeb.UserHelpers do
  @moduledoc false

  use Gettext, backend: VutuvWeb.Gettext

  import Ecto.Query
  import Ecto, only: [assoc: 2]
  import Phoenix.HTML, only: [raw: 1, safe_to_string: 1]

  alias PhoenixHTMLHelpers.Format, as: HTMLFormat
  alias PhoenixHTMLHelpers.Link, as: HTMLLink
  alias Vutuv.Accounts.User
  alias Vutuv.Profiles.Address
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.Social.Follow
  alias Vutuv.Tags.UserTag

  def full_name(%User{
        first_name: first_name,
        last_name: last_name,
        honorific_prefix: honorific_prefix,
        honorific_suffix: honorific_suffix
      }) do
    [honorific_prefix, first_name, last_name, honorific_suffix]
    |> Enum.reject(&(&1 == "" || &1 == nil))
    |> Enum.join(" ")
  end

  @doc """
  The `{label, value}` options for the Basics form's employment-status select
  (issue #870): the two real statuses derived from the schema's single source
  (`User.employment_statuses/0` mapped through `User.employment_status_label/1`,
  the same wording the profile badge and agent docs show), preceded by the
  form-local blank "not open to work" default, whose empty value `cast/3` folds
  back to nil. Building it here keeps the select from re-typing the label set.
  """
  def employment_status_options do
    [
      {gettext("Not open to work"), ""}
      | Enum.map(User.employment_statuses(), &{User.employment_status_label(&1), &1})
    ]
  end

  @doc """
  A member's display name for admin lists: their full name, or `@handle` when
  they have no name set. Shared by the admin user list and the delete flow.
  """
  def member_name(user) do
    case String.trim(full_name(user)) do
      "" -> "@" <> (user.username || "")
      name -> name
    end
  end

  @doc """
  The flash for a batch tag add, shown by `VutuvWeb.TagNewLive` (the add-tag
  form's socket save) after attaching one or more tags to the member's profile.
  """
  def tags_added_flash(successes, 0) do
    ngettext("Added %{count} tag.", "Added %{count} tags.", successes, count: successes)
  end

  def tags_added_flash(successes, failures) do
    gettext(
      "Added %{successes} of %{total} tags (the rest were duplicates or invalid).",
      successes: successes,
      total: successes + failures
    )
  end

  def name_for_email_to_field(%User{first_name: first_name, last_name: last_name}) do
    [first_name, last_name]
    |> Enum.reject(&(&1 == "" || &1 == nil))
    |> Enum.join(" ")
    |> String.replace(",", "")
    |> String.replace("<", "")
    |> String.replace(">", "")
    |> String.replace("@", "")
    |> String.replace("  ", " ")
  end

  def emails_for_display(user, visitor),
    do: emails_for_permission(user, user_has_permissions?(user, visitor))

  @doc """
  The emails to show given an already-resolved permission verdict, so a caller
  that has already decided whether the visitor may see private addresses doesn't
  re-run the follow check. `true` = every address, falsy = public only.
  """
  def emails_for_permission(user, allowed?) do
    if allowed? do
      Repo.all(Vutuv.Ordering.by_position(assoc(user, :emails)))
    else
      Repo.all(Vutuv.Ordering.by_position(from(e in assoc(user, :emails), where: e.public?)))
    end
  end

  @doc """
  Whether `visitor` may see `user`'s private (`public?: false`) email addresses.
  A private address is **owner-only**: visible to the member themselves and to
  nobody else. (It previously also granted access to everyone the owner
  *followed* — one-directional, no follow-back required — which silently exposed
  a "private" address to every account the owner subscribed to.)
  """
  def user_has_permissions?(user, visitor), do: same_user?(user, visitor)

  @doc """
  The work experience whose title/organization leads the member's profile.

  A member can pin one (issue #833) via `users.profile_work_experience_id`;
  when they have, that role wins. Otherwise it falls back to the automatic
  heuristic: the first open-ended dated role, else the first open-ended role,
  else the most recent by start date. `pinned_job/1` reads
  `user.profile_work_experience_id`, which is nil for the pre-pin default, so
  members who never touch the setting see exactly the old behaviour.
  """
  def current_job(user) do
    pinned_job(user) || heuristic_current_job(user)
  end

  # The pinned role, re-scoped to the user so a stale pointer to a foreign or
  # deleted row (the FK nils it on delete, but be defensive) never surfaces.
  defp pinned_job(%{profile_work_experience_id: id, id: user_id}) when is_binary(id) do
    Repo.one(from(w in WorkExperience, where: w.id == ^id and w.user_id == ^user_id))
  end

  defp pinned_job(_user), do: nil

  defp heuristic_current_job(user) do
    if Repo.exists?(from(w in WorkExperience, where: w.user_id == ^user.id)) do
      user
      |> has_start_no_end
      |> no_start_no_end(user)
      |> most_recent_job(user)
    end
  end

  defp has_start_no_end(user) do
    Repo.one(
      from(w in WorkExperience,
        # has a start date, no end date
        where:
          w.user_id == ^user.id and
            (not is_nil(w.start_month) and not is_nil(w.start_year)) and
            is_nil(w.end_month) and is_nil(w.end_year),
        limit: 1
      )
    )
  end

  defp no_start_no_end(nil, user) do
    Repo.one(
      from(w in WorkExperience,
        # has no end date
        where:
          w.user_id == ^user.id and
            is_nil(w.end_month) and is_nil(w.end_year),
        limit: 1
      )
    )
  end

  defp no_start_no_end(job, _), do: job

  defp most_recent_job(nil, user) do
    Repo.one(
      from(w in WorkExperience,
        where: w.user_id == ^user.id,
        limit: 1,
        order_by: [desc: w.start_year, desc: w.start_month]
      )
    )
  end

  defp most_recent_job(job, _), do: job

  @doc """
  The profile page's meta description: the current work line, optionally
  followed by a `detail` string (the member's follower count).

  Takes the controller's already-resolved current job (`:header_job`) so the
  layout does not re-run the `current_job/1` query chain the profile action
  just ran, plus a `detail` string the caller has already localized (so the
  gettext for the follower phrase stays in `VutuvWeb.OpenGraph`). Returns ""
  when neither part exists, so a bare profile falls through to the site pitch.
  """
  def meta_description(nil, _detail, _job), do: ""

  def meta_description(_user, detail, job) do
    case {work_information_string_for_job(job), detail || ""} do
      {"", ""} ->
        []

      {"", detail} ->
        [detail]

      {work, ""} ->
        [work]

      {work, detail} ->
        [work, ". ", detail]
    end
  end

  def work_information_string(user, len \\ 256)

  def work_information_string(nil, _), do: ""

  def work_information_string(user, len) do
    # Resolve the current job once; current_title/1 and current_organization/1
    # both accept a %WorkExperience{} or nil, so this avoids running the
    # current_job/1 query chain twice per call.
    case build_work_information_string(current_job(user), len) do
      "" -> headline_text(user.headline, len)
      info -> info
    end
  end

  @doc """
  The headline as a one-line plain string for list rows: inline Markdown
  markers are stripped (a row is no place for `**bold**` literals) and the
  text is truncated to `len`. Lists fall back to this when a member has no
  work experience to show.
  """
  def headline_text(headline, len \\ 256)

  def headline_text(nil, _len), do: ""

  def headline_text(headline, len) do
    text =
      headline
      |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
      |> String.replace(~r/[*_`~#>]/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(text) > len, do: String.slice(text, 0, max(len - 3, 1)) <> "...", else: text
  end

  @doc """
  Builds the work-information string from an already-resolved current job
  (a `%WorkExperience{}` or `nil`), without touching the database.

  Use this on listing pages that have batch-loaded each user's work
  experiences (see `work_information_map/2`) so a 100-row list does not run the
  per-row `current_job/1` query chain.
  """
  def work_information_string_for_job(job, len \\ 256)

  def work_information_string_for_job(job, len) do
    build_work_information_string(job, len)
  end

  defp build_work_information_string(current_job, len) do
    job = current_title(current_job)
    org = current_organization(current_job)

    "#{job}#{if org && org != "", do: " @ #{org}"}"
    |> validate_length(job, org, len)
    |> validate_backup(job, org, len)
  end

  @doc """
  In-memory equivalent of `current_job/1` for a list of work experiences that
  has already been loaded for a single user.

  Reproduces the exact precedence of the DB-backed `current_job/1` chain:

    1. the first experience that has a start (month and year) and no end
       (month and year),
    2. otherwise the first experience that has no end (month and year),
    3. otherwise the most recent experience ordered by `start_year` then
       `start_month` descending (nils sort first, as Postgres orders DESC).

  Steps 1 and 2 use `limit: 1` with no `order_by` in the DB version, which on
  Postgres yields rows in physical (insertion / id) order; we mirror that by
  preserving the list order produced by an `id`-ordered query.

  `pinned_id` (a member's `users.profile_work_experience_id`, issue #833) short-
  circuits the heuristic when it points at one of `work_experiences`: that role
  wins. nil (the default) leaves the precedence above untouched.
  """
  def current_job_in_memory(work_experiences, pinned_id \\ nil)

  def current_job_in_memory([], _pinned_id), do: nil

  def current_job_in_memory(work_experiences, pinned_id) when is_list(work_experiences) do
    pinned_in_list(work_experiences, pinned_id) || heuristic_in_memory(work_experiences)
  end

  defp pinned_in_list(_work_experiences, nil), do: nil

  defp pinned_in_list(work_experiences, pinned_id),
    do: Enum.find(work_experiences, &(&1.id == pinned_id))

  defp heuristic_in_memory(work_experiences) do
    has_start_no_end =
      Enum.find(work_experiences, fn w ->
        not is_nil(w.start_month) and not is_nil(w.start_year) and
          is_nil(w.end_month) and is_nil(w.end_year)
      end)

    has_start_no_end || no_end(work_experiences) || most_recent(work_experiences)
  end

  defp no_end(work_experiences) do
    Enum.find(work_experiences, fn w ->
      is_nil(w.end_month) and is_nil(w.end_year)
    end)
  end

  defp most_recent(work_experiences) do
    # Mirror the DB-backed most_recent_job query
    # (order_by: [desc: start_year, desc: start_month], limit: 1). Postgres
    # orders DESC with NULLS FIRST by default, so a nil start_year/start_month
    # sorts ahead of any integer (i.e. counts as "most recent"). We model that
    # by ranking a present value as {0, value} and a nil as {1, 0}, so nil keys
    # compare greater. Enum.max_by keeps the first maximal element, which on an
    # id-ordered list matches the query's physical-order tie-break.
    Enum.max_by(work_experiences, &most_recent_key/1)
  end

  defp most_recent_key(w) do
    {rank(w.start_year), rank(w.start_month)}
  end

  defp rank(nil), do: {1, 0}
  defp rank(value), do: {0, value}

  @doc """
  Batch-loads the work experiences for `users` in a single query and returns a
  map of `user_id => work_information_string(user, len)`.

  This replaces the per-row `current_job/1` query chain that
  `work_information_string/2` runs when a listing template calls it for every
  user in a 100-row list.
  """
  def work_information_map(users, len \\ 256)

  def work_information_map([], _len), do: %{}

  def work_information_map(users, len) do
    ids = Enum.map(users, & &1.id)

    experiences_by_user =
      Repo.all(from(w in WorkExperience, where: w.user_id in ^ids, order_by: w.id))
      |> Enum.group_by(& &1.user_id)

    Map.new(users, fn user ->
      job =
        current_job_in_memory(
          Map.get(experiences_by_user, user.id, []),
          user.profile_work_experience_id
        )

      info =
        case work_information_string_for_job(job, len) do
          "" -> headline_text(user.headline, len)
          info -> info
        end

      {user.id, info}
    end)
  end

  @doc """
  Resolves, in a single query, which of `users` the `current_user` already
  follows. Returns a map of `followee_id => follow_id` so a listing
  template can render the unfollow link without a per-row
  `user_follows_user?/2` query. An empty map when there is no `current_user`.
  """
  def following_map(current_user, users)

  def following_map(%User{id: follower_id}, users) when users != [] do
    ids = Enum.map(users, & &1.id)

    Repo.all(
      from(c in Follow,
        where: c.follower_id == ^follower_id and c.followee_id in ^ids,
        select: {c.followee_id, c.id}
      )
    )
    |> Map.new()
  end

  def following_map(_, _), do: %{}

  @doc """
  Each member's most popular tags and total tag count, batched in one query.

  Returns a map `user_id => %{top: [%UserTag{}], total: integer}` where `top`
  is the member's up-to-`limit` most-endorsed tags (popularity = visible
  endorsement count, ties by tag slug, the same ordering the profile page
  uses) and `total` is how many tags the member has listed. Each returned
  `UserTag` carries its `:tag` preload and the virtual `:endorsement_count`.

  Members with no tags are simply absent from the map. Like
  `work_information_map/2` and `following_map/2`, this keeps a listing's query
  count constant regardless of how many members it renders.
  """
  def tag_summary_map(users, limit \\ 3)

  def tag_summary_map([], _limit), do: %{}

  def tag_summary_map(users, limit) do
    ids = Enum.map(users, & &1.id)

    UserTag.ordered_by_endorsements()
    |> where([ut], ut.user_id in ^ids)
    |> Repo.all()
    |> Enum.group_by(& &1.user_id)
    |> Map.new(fn {user_id, user_tags} ->
      {user_id, %{top: Enum.take(user_tags, limit), total: length(user_tags)}}
    end)
  end

  defp validate_length(str, job, _org, len) do
    if String.length(str) > len do
      "#{job}"
    else
      str
    end
  end

  defp validate_backup(str, job, org, len) when len < 3 do
    validate_backup(str, job, org, 3)
  end

  defp validate_backup(str, job, _org, len) when len >= 3 do
    if String.length(str) > len do
      "#{job |> String.slice(0, len - 3)}..."
    else
      str
    end
  end

  def current_organization(nil), do: ""

  def current_organization(%WorkExperience{organization: nil}), do: ""

  def current_organization(%WorkExperience{organization: org}), do: org

  def current_title(nil), do: ""

  def current_title(%WorkExperience{title: nil}), do: ""

  def current_title(%WorkExperience{title: org}), do: org

  def locale(conn, %User{locale: nil}) do
    conn.assigns[:locale]
  end

  def locale(_conn, %User{locale: locale}) do
    locale
  end

  # Returns the follow id (or nil), not a boolean — templates use the id
  # to render the unfollow link. The query lives in the Social context.
  def user_follows_user?(%User{id: follower_id}, %User{id: followee_id}) do
    Vutuv.Social.follow_id(follower_id, followee_id)
  end

  def user_follows_user?(_, _), do: false

  def same_user?(%User{id: id}, %User{id: id}), do: true
  def same_user?(_, _), do: false

  # Renders the address as stacked lines. For a German viewer (`locale == "de"`)
  # looking at a German address the country line is dropped — see
  # `Vutuv.Address.lines/2` for the rule. Pass the viewer's locale
  # (`@conn.assigns[:locale]`) on pages that have it; `format_address/1` keeps
  # the country for callers that don't.
  def format_address(address, locale \\ nil)

  def format_address(%Address{} = address, locale) do
    address
    |> Vutuv.Address.lines(locale)
    |> Enum.join("\n")
    |> HTMLFormat.text_to_html()
  end

  def format_birthdate(%User{locale: "de", birthdate: birthdate}) do
    format_pyramid(birthdate)
  end

  def format_birthdate(%User{locale: "en", birthdate: birthdate}) do
    format_usa(birthdate)
  end

  # Legacy/pre-existing rows can carry a nil or otherwise-unrecognized locale
  # (the column has no default and no validate_inclusion); fall back to the
  # USA format instead of raising FunctionClauseError on the profile page.
  def format_birthdate(%User{birthdate: birthdate}) do
    format_usa(birthdate)
  end

  defp format_pyramid(%Date{year: year, month: month, day: day}) do
    "#{String.pad_leading(Integer.to_string(day), 2, "0")}.#{String.pad_leading(Integer.to_string(month), 2, "0")}.#{year}"
  end

  defp format_pyramid(_), do: ""

  defp format_usa(%Date{year: year, month: month, day: day}) do
    "#{String.pad_leading(Integer.to_string(month), 2, "0")}/#{String.pad_leading(Integer.to_string(day), 2, "0")}/#{year}"
  end

  defp format_usa(_), do: ""

  @doc """
  The member's age in whole years on the current German calendar day
  (`Vutuv.BerlinTime.today/0`), or `nil` when there is no birthdate or it
  lies in the future. Berlin time, so a German member's age rolls over at
  local midnight rather than at UTC midnight.
  """
  def age(%User{birthdate: birthdate}), do: age(birthdate)
  def age(%Date{} = birthdate), do: age(birthdate, Vutuv.BerlinTime.today())
  def age(_), do: nil

  @doc """
  The whole-year age of `birthdate` as of the `reference` day (both `Date`s),
  or `nil` when `reference` precedes `birthdate`. A February 29 birthday
  rolls over on March 1 in non-leap years (the `{month, day}` tuple compare).
  """
  def age(%Date{} = birthdate, %Date{} = reference) do
    had_birthday_this_year? = {reference.month, reference.day} >= {birthdate.month, birthdate.day}
    years = reference.year - birthdate.year - if(had_birthday_this_year?, do: 0, else: 1)

    if years >= 0, do: years, else: nil
  end

  def gen_breadcrumbs(args) do
    Enum.reduce(tl(args), gen_breadcrumb(hd(args)), fn f, acc ->
      "#{acc} / #{gen_breadcrumb(f)}"
    end)
    |> raw()
  end

  defp gen_breadcrumb({value, href}) do
    HTMLLink.link(value, to: href, class: "breadcrumbs__link")
    |> safe_to_string()
  end

  # Bare (unlinked) crumbs are often user-authored text (a link description, a
  # job title); the joined string ends up inside `raw/1`, so escape here.
  defp gen_breadcrumb(value) do
    value |> Phoenix.HTML.html_escape() |> safe_to_string()
  end

  def email_greeting(%User{locale: "de", last_name: nil}), do: "#{greeting("de")}"

  def email_greeting(%User{locale: "de", gender: "male", last_name: last_name}) do
    "#{greeting("de")} Herr #{last_name}"
  end

  def email_greeting(%User{locale: "de", gender: "female", last_name: last_name}) do
    "#{greeting("de")} Frau #{last_name}"
  end

  def email_greeting(%User{locale: "de", gender: _}), do: "#{greeting("de")}"

  def email_greeting(%User{locale: "en", first_name: nil}), do: "Hi"

  def email_greeting(%User{locale: "en", first_name: first_name}), do: "Hi #{first_name}"

  def email_greeting(_), do: "Hi"

  defp greeting("de") do
    %{hour: hour} = Vutuv.BerlinTime.now()

    cond do
      hour in 1..10 -> "Guten Morgen"
      hour in 11..17 -> "Hallo"
      hour in 18..23 or hour == 0 -> "Guten Abend"
      true -> "Hallo"
    end
  end

  defp greeting(_) do
    "Hi"
  end
end

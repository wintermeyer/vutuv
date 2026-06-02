defmodule VutuvWeb.UserHelpers do
  @moduledoc false

  import Ecto.Query
  import Ecto, only: [assoc: 2]
  import Phoenix.HTML, only: [raw: 1, safe_to_string: 1]

  alias PhoenixHTMLHelpers.Format, as: HTMLFormat
  alias PhoenixHTMLHelpers.Link, as: HTMLLink
  alias Vutuv.Accounts.User
  alias Vutuv.Profiles.Address
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.Social.Connection
  alias Vutuv.Tags.Tag
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

  def first_and_last(%User{first_name: first_name, last_name: last_name}, seperator \\ " ") do
    "#{first_name}#{if first_name && last_name, do: seperator}#{last_name}"
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

  def short_name(%User{first_name: nil, last_name: nil}), do: ""

  def short_name(%User{first_name: nil, last_name: last_name}) do
    String.capitalize(last_name)
  end

  def short_name(%User{first_name: first_name}) do
    String.capitalize(first_name)
  end

  def email(%User{id: id}) do
    Repo.one(from(e in Vutuv.Accounts.Email, where: e.user_id == ^id, limit: 1, select: e.value))
  end

  def emails_for_display(user, visitor) do
    if user_has_permissions?(user, visitor) do
      Repo.all(assoc(user, :emails))
    else
      Repo.all(from(e in assoc(user, :emails), where: e.public?))
    end
  end

  def user_has_permissions?(user, visitor) do
    user_follows_user?(user, visitor) || same_user?(user, visitor)
  end

  def current_job(user) do
    if Repo.one(
         from(w in WorkExperience,
           join: u in assoc(w, :user),
           where: u.id == ^user.id,
           select: count("*")
         )
       ) > 0 do
      user
      |> has_start_no_end
      |> no_start_no_end(user)
      |> most_recent_job(user)
    end
  end

  defp has_start_no_end(user) do
    Repo.one(
      from(w in WorkExperience,
        join: u in assoc(w, :user),
        # belongs to user
        # has a start date
        # has no end date
        where:
          u.id == ^user.id and
            (not is_nil(w.start_month) and not is_nil(w.start_year)) and
            is_nil(w.end_month) and is_nil(w.end_year),
        limit: 1
      )
    )
  end

  defp no_start_no_end(nil, user) do
    Repo.one(
      from(w in WorkExperience,
        join: u in assoc(w, :user),
        # belongs to user
        # has no end date
        where:
          u.id == ^user.id and
            is_nil(w.end_month) and is_nil(w.end_year),
        limit: 1
      )
    )
  end

  defp no_start_no_end(job, _), do: job

  defp most_recent_job(nil, user) do
    Repo.one(
      from(w in WorkExperience,
        join: u in assoc(w, :user),
        # belongs to user
        where: u.id == ^user.id,
        limit: 1,
        order_by: [desc: w.start_year, desc: w.start_month]
      )
    )
  end

  defp most_recent_job(job, _), do: job

  def meta_description(nil, _), do: ""
  def meta_description(_, nil), do: ""

  def meta_description(user, tags) do
    case {work_information_string(user), tags_to_string(tags)} do
      {"", ""} ->
        []

      {"", tags} ->
        ["tags: ", tags]

      {work, ""} ->
        [work]

      {work, tags} ->
        [work, ". tags: ", tags]
    end
  end

  def tags_to_string(tags) do
    for(tag <- tags) do
      UserTag.name(tag)
    end
    |> Enum.join(", ")
  end

  def work_information_string(user, len \\ 256)

  def work_information_string(nil, _), do: ""

  def work_information_string(user, len) do
    # Resolve the current job once; current_title/1 and current_organization/1
    # both accept a %WorkExperience{} or nil, so this avoids running the
    # current_job/1 query chain twice per call.
    current_job = current_job(user)
    job = current_title(current_job)
    org = current_organization(current_job)

    "#{job}#{if org && org != "", do: " @ #{org}"}"
    |> validate_length(job, org, len)
    |> validate_backup(job, org, len)
  end

  defp validate_length(str, job, _org, len) do
    if String.length(str) > len do
      "#{job}"
    else
      str
    end
  end

  defp validate_backup(str, job, org, len) when len <= 3 do
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

  def current_organization(%User{} = user) do
    current_organization(current_job(user))
  end

  def current_organization(%WorkExperience{organization: nil}), do: ""

  def current_organization(%WorkExperience{organization: org}), do: org

  def current_title(nil), do: ""

  def current_title(%User{} = user) do
    current_title(current_job(user))
  end

  def current_title(%WorkExperience{title: nil}), do: ""

  def current_title(%WorkExperience{title: org}), do: org

  def follower_count(user) do
    Repo.one(
      from(c in Connection,
        join: u in assoc(c, :follower),
        where: (is_nil(u.validated?) or u.validated? == true) and c.followee_id == ^user.id,
        select: count("follower_id")
      )
    )
  end

  def followee_count(user) do
    Repo.one(
      from(c in Connection,
        join: u in assoc(c, :followee),
        where: (is_nil(u.validated?) or u.validated? == true) and c.follower_id == ^user.id,
        select: count("followee_id")
      )
    )
  end

  def locale(conn, %User{locale: nil}) do
    conn.assigns[:locale]
  end

  def locale(_conn, %User{locale: locale}) do
    locale
  end

  def user_follows_user?(%User{id: follower_id}, %User{id: followee_id}) do
    Repo.one(
      from(c in Vutuv.Social.Connection,
        where: c.follower_id == ^follower_id and c.followee_id == ^followee_id,
        select: c.id
      )
    )
  end

  def user_follows_user?(_, _), do: false

  def visitor?(_, nil), do: false

  def visitor?(conn, current_user) do
    !same_user?(conn.assigns[:user], current_user)
  end

  def same_user?(%User{id: id}, %User{id: id}), do: true
  def same_user?(_, _), do: false

  def format_address(%Address{
        country: "United States",
        line_1: line_1,
        line_2: line_2,
        city: city,
        state: state,
        zip_code: zip_code
      }) do
    "#{line_1}#{if line_2, do: "\n" <> line_2}
    #{city}, #{state} #{zip_code}
    United States"
    |> HTMLFormat.text_to_html()
  end

  def format_address(%Address{
        country: "Germany",
        line_1: nil,
        line_2: nil,
        city: nil,
        zip_code: nil
      }) do
    "Deutschland"
    |> HTMLFormat.text_to_html()
  end

  def format_address(%Address{
        country: "Germany",
        line_1: line_1,
        line_2: line_2,
        city: city,
        zip_code: zip_code
      }) do
    "#{line_1}#{if line_2, do: "\n" <> line_2}
    #{zip_code} #{city}\nDeutschland"
    |> HTMLFormat.text_to_html()
  end

  def format_address(%Address{
        country: country,
        line_1: line_1,
        line_2: line_2,
        city: city,
        zip_code: zip_code
      }) do
    "#{line_1}#{if line_2, do: "\n" <> line_2}
    #{zip_code} #{city}
    #{country}"
    |> HTMLFormat.text_to_html()
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

  defp gen_breadcrumb(value) do
    value
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

  def greeting("de") do
    {{_, _, _}, {hour, _, _}} = :calendar.local_time()

    cond do
      hour in 1..10 -> "Guten Morgen"
      hour in 11..17 -> "Hallo"
      hour in 18..23 or hour == 0 -> "Guten Abend"
      true -> "Hallo"
    end
  end

  def greeting(_) do
    "Hi"
  end

  def admin_visitor?(conn) do
    admin?(conn.assigns[:current_user])
  end

  defp admin?(%User{administrator: admin}), do: admin

  defp admin?(_), do: false

  def has_tag?(%User{id: user_id}, %Tag{id: tag_id}) do
    !is_nil(Repo.one(from(u in UserTag, where: u.user_id == ^user_id and u.tag_id == ^tag_id)))
  end

  def has_tag?(_, _), do: false
end

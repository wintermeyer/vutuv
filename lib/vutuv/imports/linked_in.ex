defmodule Vutuv.Imports.LinkedIn do
  @moduledoc """
  Turns a member's LinkedIn data-export archive (the "Get a copy of your data"
  ZIP of CSV files) into vutuv profile candidates, then applies the ones the
  member selected.

  `parse/1` is **pure** (no Repo): it unzips in memory, classifies each CSV by
  its header signature (LinkedIn localizes the *filenames*, but the English
  header row is stable), and maps the rows onto vutuv changeset params. The
  result is a map of candidate lists the import preview renders; each candidate
  carries a stable `:id` (so the confirm step can reference it) and a human
  `:label`.

  `apply/2` is the DB side: it inserts the selected candidates in one
  transaction, reusing the existing schema changesets and skipping anything the
  member already has (so a re-import never doubles a row).

  Deliberately out of scope: `Connections.csv` (not profile data) and email
  addresses (PIN-verified identities in vutuv — surfaced read-only in the
  preview, never auto-created).
  """

  import Ecto.Query

  alias NimbleCSV.RFC4180, as: CSV
  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Profiles.Qualification
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Profiles.Url
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag

  @empty %{
    profile: %{},
    positions: [],
    educations: [],
    certifications: [],
    skills: [],
    emails: [],
    phones: [],
    urls: [],
    social: []
  }

  @month_numbers %{
    "jan" => 1,
    "january" => 1,
    "feb" => 2,
    "february" => 2,
    "mar" => 3,
    "march" => 3,
    "apr" => 4,
    "april" => 4,
    "may" => 5,
    "jun" => 6,
    "june" => 6,
    "jul" => 7,
    "july" => 7,
    "aug" => 8,
    "august" => 8,
    "sep" => 9,
    "sept" => 9,
    "september" => 9,
    "oct" => 10,
    "october" => 10,
    "nov" => 11,
    "november" => 11,
    "dec" => 12,
    "december" => 12
  }

  @doc """
  Parses a LinkedIn export ZIP (a binary) into candidate lists. Returns
  `{:error, :invalid_archive}` for anything that is not a readable ZIP.
  """
  def parse(zip_binary) when is_binary(zip_binary) do
    do_parse(zip_binary)
  end

  @doc """
  Like `parse/1`, but reads the ZIP from a file on disk (the uploaded temp
  file), so the archive is never loaded into memory whole — `:zip` only
  inflates the selected small entries.
  """
  def parse_file(path) when is_binary(path) do
    do_parse(String.to_charlist(path))
  end

  # `:zip` accepts both an in-memory binary and a filename charlist.
  defp do_parse(zip_source) do
    with {:ok, names} <- safe_entry_names(zip_source),
         {:ok, files} <- extract(zip_source, names) do
      {:ok, build(files)}
    end
  end

  # Zip-bomb defense. The CSVs we need (profile, positions, volunteering,
  # education, skills, phone) are tiny; a LinkedIn export's bulk (connections,
  # messages, media) we
  # don't touch. So we read the ZIP's central directory FIRST (no decompression),
  # then:
  #   * skip any single entry that declares more than @max_entry_bytes — the big
  #     message dumps, and any honest bomb whose header admits its size;
  #   * refuse the whole archive if it has more than @max_entries members, or if
  #     the entries we would actually extract already declare more than
  #     @max_total_bytes uncompressed.
  # Only the surviving small entries are decompressed, so a classic bomb (e.g.
  # 42.zip, whose members declare petabytes) is rejected before any inflation.
  # The compressed upload is also capped in the controller (@max_upload_bytes),
  # which bounds the worst case for a spoofed-header single stream.
  @max_entries 2_000
  @max_entry_bytes 15_000_000
  @max_total_bytes 40_000_000

  defp safe_entry_names(zip_source) do
    case :zip.list_dir(zip_source) do
      {:ok, table} ->
        entries =
          for {:zip_file, name, info, _comment, _offset, _comp} <- table,
              not directory?(name),
              do: {name, elem(info, 1)}

        if length(entries) > @max_entries do
          {:error, :archive_too_large}
        else
          select_entries(entries)
        end

      {:error, _} ->
        {:error, :invalid_archive}
    end
  rescue
    _ -> {:error, :invalid_archive}
  end

  # Keep only entries small enough to be a real CSV, and refuse if their total
  # declared uncompressed size is still too big.
  defp select_entries(entries) do
    kept = for {name, size} <- entries, size <= @max_entry_bytes, do: {name, size}
    total = Enum.reduce(kept, 0, fn {_name, size}, acc -> acc + size end)

    if total > @max_total_bytes do
      {:error, :archive_too_large}
    else
      {:ok, Enum.map(kept, fn {name, _size} -> name end)}
    end
  end

  defp directory?(name), do: List.last(name) == ?/

  defp extract(_zip_source, []), do: {:ok, []}

  defp extract(zip_source, names) do
    case :zip.unzip(zip_source, [:memory, {:file_list, names}]) do
      {:ok, entries} ->
        {:ok,
         Enum.map(entries, fn {name, content} -> {to_string(name), ensure_utf8(content)} end)}

      {:error, _reason} ->
        {:error, :invalid_archive}
    end
  rescue
    _ -> {:error, :invalid_archive}
  end

  # LinkedIn writes UTF-8, but a member who opens a CSV in Excel and re-saves
  # it before re-zipping ships Windows-1252/Latin-1 bytes. Everything
  # downstream assumes valid UTF-8 (Jason.encode! of the preview payload
  # raises on a stray byte and 500ed the upload), so transcode anything
  # invalid as Latin-1 — total, since every byte is a Latin-1 codepoint.
  defp ensure_utf8(content) do
    case :unicode.characters_to_binary(content) do
      valid when is_binary(valid) -> valid
      _ -> :unicode.characters_to_binary(content, :latin1, :utf8)
    end
  end

  defp build(files) do
    rows_by_type = classify_all(files)

    {profile, profile_urls, profile_social} =
      rows_by_type |> Map.get(:profile, []) |> List.first() |> parse_profile()

    positions = rows_by_type |> Map.get(:positions, []) |> Enum.map(&position_candidate/1)

    # Volunteering.csv (issue #840) joins the positions list as work
    # experiences with kind "volunteer", so the whole preview/apply pipeline
    # handles them like any other role.
    volunteering =
      rows_by_type |> Map.get(:volunteering, []) |> Enum.map(&volunteer_candidate/1)

    %{
      profile: profile,
      positions: tidy(positions ++ volunteering),
      educations:
        rows_by_type |> Map.get(:educations, []) |> Enum.map(&education_candidate/1) |> tidy(),
      certifications:
        rows_by_type
        |> Map.get(:certifications, [])
        |> Enum.map(&certification_candidate/1)
        |> tidy(),
      skills: rows_by_type |> Map.get(:skills, []) |> parse_skills(),
      emails: rows_by_type |> Map.get(:emails, []) |> Enum.map(&email_info/1),
      phones: rows_by_type |> Map.get(:phones, []) |> Enum.map(&phone_candidate/1) |> tidy(),
      urls: tidy(profile_urls),
      social: tidy(profile_social)
    }
  end

  # Candidate hygiene: drop rows missing their essentials (a blank row can only
  # fail — or insert an empty shell — at apply time, and renders an empty
  # preview checkbox until then), then collapse duplicates. Real archives
  # repeat entries across files, sometimes formatted differently ("+49 1515 …"
  # vs "49151…"); the content-hash candidate id (cid/2) is built from the
  # normalized essence, so those collide here on purpose and one survives.
  defp tidy(candidates) do
    candidates |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.id)
  end

  # Group every readable CSV's rows (as header=>value maps) under a type derived
  # from its header signature. Unknown files and the deliberately-skipped
  # Connections.csv are dropped.
  defp classify_all(files) do
    Enum.reduce(files, %{}, fn {name, content}, acc -> classify_file(acc, name, content) end)
  end

  defp classify_file(acc, name, content) do
    case parse_csv(content) do
      [headers | data] -> add_rows(acc, classify(name, headers), headers, data)
      _ -> acc
    end
  end

  defp add_rows(acc, type, _headers, _data) when type in [:unknown, :connections], do: acc

  defp add_rows(acc, type, headers, data) do
    rows = Enum.map(data, &row_map(headers, &1))
    Map.update(acc, type, rows, &(&1 ++ rows))
  end

  defp parse_csv(content) do
    content
    |> String.replace_prefix("﻿", "")
    |> CSV.parse_string(skip_headers: false)
  rescue
    _ -> []
  end

  defp row_map(headers, values) do
    padded = values ++ List.duplicate("", max(length(headers) - length(values), 0))

    headers
    |> Enum.zip(padded)
    |> Map.new(fn {header, value} -> {String.trim(header), value} end)
  end

  # Classify by header signature (filename-independent), with an English
  # filename fallback for the odd export whose headers we don't recognize.
  # First matching signature wins, so :positions (Title) is checked before
  # :volunteering (Role).
  @header_signatures [
    positions: ["Company Name", "Title"],
    volunteering: ["Company Name", "Role"],
    educations: ["School Name"],
    # Certifications.csv: Name, Url, Authority, Started On, Finished On,
    # License Number. "Name" + "Authority" together are unique to this file.
    certifications: ["Name", "Authority"],
    connections: ["Connected On"],
    profile: ["First Name", "Headline"],
    phones: ["Number"],
    emails: ["Email Address"]
  ]

  defp classify(_name, ["Name"]), do: :skills

  defp classify(name, headers) do
    set = MapSet.new(headers)

    Enum.find_value(@header_signatures, filename_fallback(name), fn {type, required} ->
      if subset?(required, set), do: type
    end)
  end

  # An English filename prefix -> candidate type, for the odd export whose
  # header row we don't recognize. First matching prefix wins.
  @filename_prefixes [
    {"positions", :positions},
    {"volunteering", :volunteering},
    {"education", :educations},
    {"certification", :certifications},
    {"skills", :skills},
    {"profile", :profile},
    {"phonenumbers", :phones},
    {"connections", :connections}
  ]

  defp filename_fallback(name) do
    base = name |> Path.basename() |> String.downcase()

    Enum.find_value(@filename_prefixes, :unknown, fn {prefix, type} ->
      if String.starts_with?(base, prefix), do: type
    end)
  end

  defp subset?(keys, set), do: Enum.all?(keys, &MapSet.member?(set, &1))

  # ── Profile.csv → name/headline scalars + Websites/Twitter candidates ──

  defp parse_profile(nil), do: {%{}, [], []}

  defp parse_profile(row) do
    profile =
      %{
        first_name: blank_nil(row["First Name"]),
        last_name: blank_nil(row["Last Name"]),
        headline: blank_nil(row["Headline"])
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    {profile, parse_websites(row["Websites"]), parse_twitter(row["Twitter Handles"])}
  end

  # Websites look like `[PORTFOLIO:https://x.example,BLOG:https://y.example]`:
  # bracketed, comma-separated `LABEL:url` items. A rare label-less entry is a
  # bare URL.
  defp parse_websites(value) do
    value
    |> bracket_list()
    |> Enum.map(&website_candidate/1)
    |> Enum.reject(&is_nil/1)
  end

  defp website_candidate(item) do
    {description, url} =
      case String.split(item, ":", parts: 2) do
        [scheme, _rest] when scheme in ~w(http https ftp) -> {nil, item}
        [label, url] -> {titleize(label), String.trim(url)}
        [url] -> {nil, url}
      end

    case blank_nil(url) do
      nil ->
        nil

      url ->
        %{
          id: cid("url", String.downcase(url)),
          label: description || url,
          params: %{"value" => url, "description" => description}
        }
    end
  end

  # Twitter Handles look like `[handle1,handle2]`.
  defp parse_twitter(value) do
    value
    |> bracket_list()
    |> Enum.map(fn handle ->
      %{
        id: cid("social", "twitter|" <> String.downcase(handle)),
        label: "Twitter: #{handle}",
        params: %{"provider" => "Twitter", "value" => handle}
      }
    end)
  end

  defp bracket_list(nil), do: []

  defp bracket_list(value) do
    value
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # ── Positions.csv → WorkExperience params ──

  defp position_candidate(row) do
    {sm, sy} = parse_month_year(row["Started On"])
    {em, ey} = parse_month_year(row["Finished On"])
    org = blank_nil(row["Company Name"])
    title = blank_nil(row["Title"])

    # Both are required by WorkExperience.changeset — a row missing either
    # could never import.
    if is_nil(org) or is_nil(title) do
      nil
    else
      %{
        id: cid("position", "#{downcase(org)}|#{downcase(title)}"),
        label: [title, org] |> compact() |> Enum.join(" @ "),
        params: %{
          "organization" => org,
          "title" => title,
          "description" => blank_nil(row["Description"]),
          "start_month" => sm,
          "start_year" => sy,
          "end_month" => em,
          "end_year" => ey
        }
      }
    end
  end

  # ── Volunteering.csv → WorkExperience params (kind: volunteer, issue #840) ──

  defp volunteer_candidate(row) do
    {sm, sy} = parse_month_year(row["Started On"] || row["Start Date"])
    {em, ey} = parse_month_year(row["Finished On"] || row["End Date"])
    org = blank_nil(row["Company Name"])
    title = blank_nil(row["Role"])

    # LinkedIn files the cause ("Environment", …) in its own column; folding it
    # into the description keeps it without a schema field of its own.
    description =
      [blank_nil(row["Cause"]), blank_nil(row["Description"])]
      |> compact()
      |> Enum.join(" · ")
      |> blank_nil()

    if is_nil(org) or is_nil(title) do
      nil
    else
      %{
        id: cid("volunteer", "#{downcase(org)}|#{downcase(title)}"),
        label: [title, org] |> compact() |> Enum.join(" @ "),
        params: %{
          "organization" => org,
          "title" => title,
          "kind" => "volunteer",
          "description" => description,
          "start_month" => sm,
          "start_year" => sy,
          "end_month" => em,
          "end_year" => ey
        }
      }
    end
  end

  # ── Education.csv → Education params ──

  defp education_candidate(row) do
    {sm, sy} = parse_month_year(row["Start Date"])
    {em, ey} = parse_month_year(row["End Date"])
    school = blank_nil(row["School Name"])
    degree = blank_nil(row["Degree Name"])

    # The school is required by Education.changeset — a school-less row could
    # never import.
    if is_nil(school) do
      nil
    else
      %{
        id: cid("education", "#{downcase(school)}|#{downcase(degree)}"),
        label: [degree, school] |> compact() |> Enum.join(", "),
        params: %{
          "school" => school,
          "degree" => degree,
          "description" => education_notes(row),
          "start_month" => sm,
          "start_year" => sy,
          "end_month" => em,
          "end_year" => ey
        }
      }
    end
  end

  defp education_notes(row) do
    [row["Notes"], row["Activities"]]
    |> compact()
    |> Enum.join("\n")
    |> blank_nil()
  end

  # ── Certifications.csv → Qualification params (issue #859) ──
  #
  # LinkedIn drops no licence/certificate distinction, so every imported row
  # lands as a certification; the preview tells the member to check the section.
  # "Started On" is the award date, "Finished On" the (optional) expiry.

  defp certification_candidate(row) do
    name = blank_nil(row["Name"])

    # The name is required by Qualification.changeset — a nameless row could
    # never import, so it is dropped here (like a school-less education).
    if is_nil(name) do
      nil
    else
      {am, ay} = parse_month_year(row["Started On"])
      {em, ey} = parse_month_year(row["Finished On"])
      issuer = blank_nil(row["Authority"])

      %{
        id: cid("certification", "#{downcase(name)}|#{downcase(issuer)}"),
        label: [name, issuer] |> compact() |> Enum.join(", "),
        params: %{
          "name" => name,
          "kind" => "certification",
          "issuer" => issuer,
          "awarded_month" => am,
          "awarded_year" => ay,
          "expires_month" => em,
          "expires_year" => ey,
          "credential_id" => blank_nil(row["License Number"]),
          "url" => blank_nil(row["Url"])
        }
      }
    end
  end

  # ── Skills.csv → tag candidates ──
  #
  # One CSV row is one skill, and tags may contain spaces now, so a multi-word
  # LinkedIn skill ("Ruby on Rails") stays a single candidate the member can
  # accept or prune whole (it is not exploded into "Ruby"/"on"/"Rails").
  defp parse_skills(rows) do
    rows
    |> Enum.map(fn row -> Tag.normalize_value(row["Name"] || "") end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.map(fn name ->
      %{id: cid("skill", String.downcase(name)), label: name, name: name}
    end)
  end

  # ── PhoneNumbers.csv → PhoneNumber params ──

  # nil for a number-less row; the id hashes the digits alone, so the same
  # number in two formats is one candidate.
  defp phone_candidate(row) do
    case blank_nil(row["Number"]) do
      nil ->
        nil

      number ->
        %{
          id: cid("phone", digits(number)),
          label: number,
          params: %{"value" => number, "number_type" => phone_type(row["Type"])}
        }
    end
  end

  defp phone_type(type) do
    case downcase(type) do
      "home" -> "Home"
      "work" -> "Work"
      "fax" -> "Fax"
      # mobile / cell / unknown all map to the default.
      _ -> "Cell"
    end
  end

  # ── Email Addresses.csv → read-only info (never imported) ──

  defp email_info(row) do
    %{value: blank_nil(row["Email Address"]), primary: downcase(row["Primary"]) == "yes"}
  end

  # ── Dates ──

  @doc """
  Parses a LinkedIn date cell into `{month, year}` (either may be nil):
  `"Jan 2020" -> {1, 2020}`, `"2020" -> {nil, 2020}`, `"" -> {nil, nil}`.
  LinkedIn month names are always English regardless of the account UI language.
  """
  def parse_month_year(nil), do: {nil, nil}

  def parse_month_year(value) do
    case value |> to_string() |> String.trim() |> String.split(~r/\s+/, trim: true) do
      [] -> {nil, nil}
      [year] -> {nil, to_year(year)}
      [month, year] -> {to_month(month), to_year(year)}
      _ -> {nil, nil}
    end
  end

  defp to_month(token), do: Map.get(@month_numbers, String.downcase(token))

  defp to_year(token) do
    case Integer.parse(token) do
      {year, _} when year >= 1900 and year <= 2100 -> year
      _ -> nil
    end
  end

  # ── Apply (the DB side) ──

  # The profile scalars the import can fill (name + headline). Order drives the
  # preview list.
  @profile_fields [first_name: "First name", last_name: "Last name", headline: "Headline"]

  # "first_name" => :first_name … the whitelist pick_profile/2 maps client keys
  # through, so a tampered payload key is dropped instead of crashing
  # String.to_existing_atom/1 with an ArgumentError (a 500 on import confirm).
  @allowed_profile_fields Map.new(@profile_fields, fn {k, _} -> {Atom.to_string(k), k} end)

  @doc """
  Marks each candidate with `duplicate?: true` when the member already has it,
  and turns the profile scalars into display candidates (with `fillable?`, so the
  preview can offer only the fields that are currently blank). For rendering the
  preview only; the apply step re-checks duplicates inside its transaction.
  """
  def mark_duplicates(user, parsed) do
    existing = existing_keys(user)

    %{
      positions: mark(parsed.positions, existing.positions, &position_key(&1.params)),
      educations: mark(parsed.educations, existing.educations, &education_key(&1.params)),
      certifications:
        mark(parsed.certifications, existing.certifications, &certification_key(&1.params)),
      urls: mark(parsed.urls, existing.urls, &downcase(&1.params["value"])),
      social: mark(parsed.social, existing.social, &social_key(&1.params)),
      phones: mark(parsed.phones, existing.phones, &digits(&1.params["value"])),
      skills: mark(parsed.skills, existing.skills, &String.downcase(&1.name)),
      emails: parsed.emails,
      profile: profile_candidates(user, parsed.profile)
    }
  end

  defp mark(candidates, seen, key_fun) do
    Enum.map(candidates, fn c -> Map.put(c, :duplicate?, MapSet.member?(seen, key_fun.(c))) end)
  end

  defp profile_candidates(user, profile) do
    for {field, label} <- @profile_fields,
        value = Map.get(profile, field),
        not is_nil(value) do
      %{
        id: "profile:#{field}",
        field: field,
        label: label,
        value: value,
        fillable?: blank_field?(user, field)
      }
    end
  end

  @doc """
  The candidate data the preview form carries in one hidden field (JSON), so the
  confirm step is stateless (the cookie session is too small for a heavy export).
  Only the id + the changeset payload per candidate — no display strings.
  """
  def payload_map(parsed) do
    %{
      "positions" => Enum.map(parsed.positions, &Map.take(&1, [:id, :params])),
      "educations" => Enum.map(parsed.educations, &Map.take(&1, [:id, :params])),
      "certifications" => Enum.map(parsed.certifications, &Map.take(&1, [:id, :params])),
      "urls" => Enum.map(parsed.urls, &Map.take(&1, [:id, :params])),
      "social" => Enum.map(parsed.social, &Map.take(&1, [:id, :params])),
      "phones" => Enum.map(parsed.phones, &Map.take(&1, [:id, :params])),
      "skills" => Enum.map(parsed.skills, &Map.take(&1, [:id, :name])),
      "profile" => parsed.profile
    }
  end

  @doc """
  Rebuilds an apply selection from the decoded payload map (string keys) and the
  set of checkbox ids the member submitted. The payload is client-controlled, but
  every insert goes through the owner-scoped schema changesets in
  `apply_selection/2`, so a tampered payload can only ever create entries on the
  member's own profile — exactly what the normal new-entry forms already allow.
  """
  def selection_from_payload(payload, selected) when is_map(payload) and is_list(selected) do
    set = MapSet.new(selected)

    %{
      positions: pick(payload["positions"], set),
      educations: pick(payload["educations"], set),
      certifications: pick(payload["certifications"], set),
      urls: pick(payload["urls"], set),
      social: pick(payload["social"], set),
      phones: pick(payload["phones"], set),
      skills: pick_skills(payload["skills"], set),
      profile: pick_profile(payload["profile"], set)
    }
  end

  defp pick(nil, _set), do: []

  defp pick(list, set),
    do: for(c <- list, MapSet.member?(set, c["id"]), do: %{params: c["params"]})

  defp pick_skills(nil, _set), do: []

  defp pick_skills(list, set),
    do: for(c <- list, MapSet.member?(set, c["id"]), do: %{name: c["name"]})

  defp pick_profile(nil, _set), do: %{}

  defp pick_profile(profile, set) do
    for {field, value} <- profile,
        MapSet.member?(set, "profile:#{field}"),
        Map.has_key?(@allowed_profile_fields, field),
        into: %{},
        do: {@allowed_profile_fields[field], value}
  end

  @doc """
  Inserts the selected candidates for `user` in one transaction, skipping
  anything the member already has (so re-import never doubles a row). `selection`
  is the parse result narrowed to the chosen candidates, plus a `:profile` map of
  the blank fields to fill. Returns `{:ok, %{created: map, skipped: map}}`.
  """
  def apply_selection(user, selection) do
    Repo.transaction(fn ->
      existing = existing_keys(user)

      {existing, positions} =
        insert_scoped(existing, :positions, Map.get(selection, :positions, []), fn c ->
          {position_key(c.params), &WorkExperience.changeset(&1, c.params), :work_experiences}
        end)

      {existing, educations} =
        insert_scoped(existing, :educations, Map.get(selection, :educations, []), fn c ->
          {education_key(c.params), &Education.changeset(&1, c.params), :educations}
        end)

      {existing, certifications} =
        insert_scoped(existing, :certifications, Map.get(selection, :certifications, []), fn c ->
          {certification_key(c.params), &Qualification.changeset(&1, c.params), :qualifications}
        end)

      {existing, urls} =
        insert_scoped(existing, :urls, Map.get(selection, :urls, []), fn c ->
          {downcase(c.params["value"]), &Url.changeset(&1, c.params), :urls}
        end)

      {existing, social} =
        insert_scoped(existing, :social, Map.get(selection, :social, []), fn c ->
          {social_key_unless_claimed(c.params), &SocialMediaAccount.changeset(&1, c.params),
           :social_media_accounts}
        end)

      {existing, phones} =
        insert_scoped(existing, :phones, Map.get(selection, :phones, []), fn c ->
          {digits(c.params["value"]), &PhoneNumber.changeset(&1, c.params), :phone_numbers}
        end)

      {_existing, skills} = insert_skills(user, existing, Map.get(selection, :skills, []))

      profile = apply_profile(user, Map.get(selection, :profile, %{}))

      %{
        created: %{
          positions: positions.created,
          educations: educations.created,
          certifications: certifications.created,
          urls: urls.created,
          social: social.created,
          phones: phones.created,
          skills: skills.created,
          profile: profile
        },
        skipped: %{
          positions: positions.skipped,
          educations: educations.skipped,
          certifications: certifications.skipped,
          urls: urls.skipped,
          social: social.skipped,
          phones: phones.skipped,
          skills: skills.skipped
        }
      }
    end)
  end

  # Insert each candidate whose dedup key is not already present (in the DB or
  # earlier in this same batch), building the row off the user association.
  defp insert_scoped(existing, type, candidates, fun) do
    uid = user_id(existing)
    seen = Map.fetch!(existing, type)

    {seen, created, skipped} =
      Enum.reduce(candidates, {seen, 0, 0}, &insert_one(&1, &2, fun, uid))

    {Map.put(existing, type, seen), %{created: created, skipped: skipped}}
  end

  defp insert_one(candidate, acc, fun, uid) do
    {key, changeset_fun, assoc} = fun.(candidate)
    do_insert(key, changeset_fun, assoc, acc, uid)
  end

  defp do_insert(nil, _changeset_fun, _assoc, {seen, created, skipped}, _uid),
    do: {seen, created, skipped + 1}

  defp do_insert(key, changeset_fun, assoc, {seen, created, skipped} = acc, uid) do
    if MapSet.member?(seen, key) do
      {seen, created, skipped + 1}
    else
      # on_conflict: :nothing — every insert here runs inside apply_selection's
      # single transaction, and a unique-index violation (even one a changeset
      # declares, which Ecto softens to {:error, changeset}) would abort that
      # transaction at the Postgres level: every insert after it then dies with
      # 25P02 and the whole import 500s. The deterministic cases are
      # pre-filtered (per-user keys, the globally-claimed social check), so
      # what's left is races and the global slug indexes — DO NOTHING degrades
      # those to a no-op row. Such a raced no-op counts as created even though
      # nothing landed; a cosmetic miscount in the summary, never a crash.
      changeset_fun.(Ecto.build_assoc(%User{id: uid}, assoc))
      |> Repo.insert(on_conflict: :nothing)
      |> tally(key, acc)
    end
  end

  defp insert_skills(user, existing, candidates) do
    seen = Map.fetch!(existing, :skills)
    {seen, created, skipped} = Enum.reduce(candidates, {seen, 0, 0}, &add_skill(&1, &2, user))
    {Map.put(existing, :skills, seen), %{created: created, skipped: skipped}}
  end

  defp add_skill(candidate, {seen, created, skipped} = acc, user) do
    key = String.downcase(candidate.name)

    if MapSet.member?(seen, key) do
      {seen, created, skipped + 1}
    else
      user |> Tags.add_user_tag(candidate.name) |> tally(key, acc)
    end
  end

  # A successful insert counts as created and remembers its key; a failure (a
  # racing duplicate, an invalid row) counts as skipped.
  defp tally({:ok, _row}, key, {seen, created, skipped}),
    do: {MapSet.put(seen, key), created + 1, skipped}

  defp tally({:error, _}, _key, {seen, created, skipped}), do: {seen, created, skipped + 1}

  # Fill only the blank profile fields the member selected (name / headline).
  # Guards here too, not just in the controller, so an import can never clobber
  # an existing name or headline.
  defp apply_profile(_user, profile) when map_size(profile) == 0, do: []

  defp apply_profile(user, profile) do
    fillable =
      profile |> Enum.filter(fn {field, _v} -> blank_field?(user, field) end) |> Map.new()

    if map_size(fillable) == 0 do
      []
    else
      case Accounts.update_user(user, fillable) do
        {:ok, _user} -> Map.keys(fillable)
        {:error, _} -> []
      end
    end
  end

  defp blank_field?(user, field) do
    key = if is_atom(field), do: field, else: String.to_existing_atom(field)

    case Map.get(user, key) do
      nil -> true
      value when is_binary(value) -> String.trim(value) == ""
      _ -> false
    end
  end

  # The dedup sets, loaded once, plus the user id so the inserts can build_assoc.
  defp existing_keys(user) do
    %{
      __user_id__: user.id,
      positions:
        keys(WorkExperience, user.id, fn r ->
          position_key(%{"organization" => r.organization, "title" => r.title})
        end),
      educations:
        keys(Education, user.id, fn r ->
          education_key(%{"school" => r.school, "degree" => r.degree})
        end),
      certifications:
        keys(Qualification, user.id, fn r ->
          certification_key(%{"name" => r.name, "issuer" => r.issuer})
        end),
      urls: keys(Url, user.id, fn r -> downcase(r.value) end),
      social:
        keys(SocialMediaAccount, user.id, fn r ->
          social_key(%{"provider" => r.provider, "value" => r.value})
        end),
      phones: keys(PhoneNumber, user.id, fn r -> digits(r.value) end),
      skills: skill_keys(user.id)
    }
  end

  defp user_id(existing), do: Map.fetch!(existing, :__user_id__)

  defp keys(schema, user_id, key_fun) do
    from(r in schema, where: r.user_id == ^user_id)
    |> Repo.all()
    |> Enum.map(key_fun)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp skill_keys(user_id) do
    from(ut in UserTag,
      join: t in assoc(ut, :tag),
      where: ut.user_id == ^user_id,
      select: t.name
    )
    |> Repo.all()
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp position_key(%{"organization" => org, "title" => title}) do
    case {downcase(org), downcase(title)} do
      {nil, nil} -> nil
      {o, t} -> "#{o}|#{t}"
    end
  end

  defp education_key(%{"school" => school, "degree" => degree}) do
    case downcase(school) do
      nil -> nil
      s -> "#{s}|#{downcase(degree)}"
    end
  end

  defp certification_key(%{"name" => name} = params) do
    case downcase(name) do
      nil -> nil
      n -> "#{n}|#{downcase(params["issuer"])}"
    end
  end

  defp social_key(%{"provider" => provider, "value" => value}),
    do: "#{downcase(provider)}|#{downcase(value)}"

  # The (value, provider) unique index on social_media_accounts is GLOBAL — a
  # handle another member already claimed can never be imported. A nil key
  # routes the candidate into do_insert's skipped path, so the insert never
  # fires the constraint (which would abort the surrounding import transaction
  # and 25P02-crash every insert after it; "Someone has already claimed this
  # account" is the constraint's own user-facing message elsewhere).
  defp social_key_unless_claimed(%{"provider" => provider, "value" => value} = params) do
    claimed? =
      Repo.exists?(
        from(s in SocialMediaAccount, where: s.value == ^value and s.provider == ^provider)
      )

    if claimed?, do: nil, else: social_key(params)
  end

  # ── Small helpers ──

  defp blank_nil(nil), do: nil

  defp blank_nil(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp compact(list), do: Enum.reject(list, &is_nil/1)

  defp downcase(nil), do: nil
  defp downcase(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp digits(nil), do: nil
  defp digits(value), do: value |> to_string() |> String.replace(~r/\D/, "")

  # String.capitalize/1 already downcases the tail, so no separate downcase.
  defp titleize(label), do: String.capitalize(label)

  # A stable id for a candidate: a hash of its semantic key. Deterministic for
  # the same term across nodes (:erlang.phash2), so the preview → confirm round
  # trip (candidates stored in the session) keeps matching ids.
  defp cid(kind, key), do: "#{kind}_#{:erlang.phash2({kind, key})}"

  @doc "An empty parse result (no archive / all-unknown files)."
  def empty, do: @empty
end

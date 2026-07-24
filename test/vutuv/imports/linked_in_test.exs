defmodule Vutuv.Imports.LinkedInTest do
  @moduledoc """
  The pure LinkedIn export parser (no Repo). Archives are built in memory from
  CSV strings, so the fixtures live in the test and stay readable.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Imports.LinkedIn

  # A real Profile.csv header + row from an actual export (note the bracketed
  # `[LABEL:url]` Websites and `[handle]` Twitter Handles formats).
  @profile_headers "First Name,Last Name,Maiden Name,Address,Birth Date,Headline,Summary,Industry,Zip Code,Geo Location,Twitter Handles,Websites,Instant Messengers"
  @profile_row ~s(Stefan,Wintermeyer,,56068 Koblenz,,"Human. Not an agent.",,IT Services,56068,"Coblenz, Germany",[wintermeyer],[PORTFOLIO:https://wintermeyer-consulting.de],)

  defp zip(files) do
    entries = Enum.map(files, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, {_name, binary}} = :zip.create(~c"export.zip", entries, [:memory])
    binary
  end

  defp profile_csv, do: @profile_headers <> "\n" <> @profile_row <> "\n"

  # ── Malicious-archive builders (craft what :zip.create won't) ──

  # Overwrite the 4-byte little-endian field at absolute byte `pos` in `bin`.
  defp patch_u32(bin, pos, value) do
    binary_part(bin, 0, pos) <>
      <<value::little-32>> <> binary_part(bin, pos + 4, byte_size(bin) - pos - 4)
  end

  # A single real deflate entry whose central-directory *declared* uncompressed
  # size is overwritten to a small lie, so the cheap declared-size pre-filter
  # keeps it while the stream actually inflates to `byte_size(actual)`.
  # (Central-directory file header: uncompressed size is the 4 bytes at +24.)
  defp bomb_zip(actual, declared_size) do
    {:ok, {_n, bin}} = :zip.create(~c"bomb.zip", [{~c"Connections.csv", actual}], [:memory])
    {cd, _} = :binary.match(bin, <<0x50, 0x4B, 0x01, 0x02>>)
    patch_u32(bin, cd + 24, declared_size)
  end

  # `count` central-directory records all pointing at ONE local header (offset 0),
  # i.e. `count` entries that share a single deflate stream — the "inflate one
  # stream N times" attack. Built by duplicating the single record and rewriting
  # the end-of-central-directory record's counts/sizes.
  defp shared_offset_zip(count) do
    # ~300 KB of real, compressible data at offset 0 — the stream the naive
    # attack would inflate once per central-directory entry.
    stream = :binary.copy("data,row,value\n", 20_000)
    {:ok, {_n, bin}} = :zip.create(~c"s.zip", [{~c"x.csv", stream}], [:memory])
    {cd_start, _} = :binary.match(bin, <<0x50, 0x4B, 0x01, 0x02>>)
    {eocd_start, _} = :binary.match(bin, <<0x50, 0x4B, 0x05, 0x06>>)
    prefix = binary_part(bin, 0, cd_start)
    # Each copy declares a tiny uncompressed size (+24 in the record), so the
    # archive clears the declared-size pre-filter and reaches the overlap check —
    # mirroring an attack whose entries all lie about their size.
    cdfh = patch_u32(binary_part(bin, cd_start, eocd_start - cd_start), 24, 5_000)
    eocd = binary_part(bin, eocd_start, byte_size(bin) - eocd_start)
    new_cd = :binary.copy(cdfh, count)

    <<sig::binary-size(4), disk::binary-size(4), _recs1::little-16, _recs2::little-16,
      _cd_size::little-32, _cd_off::little-32, rest::binary>> = eocd

    new_eocd =
      <<sig::binary-size(4), disk::binary-size(4), count::little-16, count::little-16,
        byte_size(new_cd)::little-32, byte_size(prefix)::little-32, rest::binary>>

    prefix <> new_cd <> new_eocd
  end

  # Two kept entries whose data regions overlap: entry b's central-directory
  # local-header offset (+42 in the record) is patched to point at entry a's.
  defp overlapping_zip do
    {:ok, {_n, bin}} =
      :zip.create(~c"o.zip", [{~c"a.csv", "aaaa\n"}, {~c"b.csv", "bbbb\n"}], [:memory])

    [_first, {second, _}] = :binary.matches(bin, <<0x50, 0x4B, 0x01, 0x02>>)
    patch_u32(bin, second + 42, 0)
  end

  describe "parse/1 errors" do
    test "a non-zip binary is an invalid archive" do
      assert LinkedIn.parse("this is not a zip file") == {:error, :invalid_archive}
    end
  end

  describe "Profile.csv" do
    test "extracts name and headline, and websites/twitter as candidates" do
      {:ok, result} = LinkedIn.parse(zip([{"Profile.csv", profile_csv()}]))

      assert result.profile.first_name == "Stefan"
      assert result.profile.last_name == "Wintermeyer"
      assert result.profile.headline == "Human. Not an agent."

      assert [
               %{
                 params: %{
                   "value" => "https://wintermeyer-consulting.de",
                   "description" => "Portfolio"
                 }
               }
             ] =
               result.urls

      assert [%{params: %{"provider" => "Twitter", "value" => "wintermeyer"}}] = result.social
    end

    test "tolerates a UTF-8 BOM and CRLF line endings" do
      bom = "﻿"
      crlf = String.replace(profile_csv(), "\n", "\r\n")
      {:ok, result} = LinkedIn.parse(zip([{"Profile.csv", bom <> crlf}]))

      assert result.profile.first_name == "Stefan"
    end
  end

  describe "Positions.csv" do
    test "maps positions with month/year date parsing" do
      csv = """
      Company Name,Title,Description,Location,Started On,Finished On
      Acme,Engineer,Built stuff,Berlin,Jan 2020,Mar 2022
      Beta,CTO,,,2018,
      """

      {:ok, result} = LinkedIn.parse(zip([{"Positions.csv", csv}]))

      assert [acme, beta] = result.positions

      assert acme.params == %{
               "organization" => "Acme",
               "title" => "Engineer",
               "description" => "Built stuff",
               "start_month" => 1,
               "start_year" => 2020,
               "end_month" => 3,
               "end_year" => 2022
             }

      assert beta.params["start_year"] == 2018
      assert beta.params["start_month"] == nil
      assert beta.params["end_year"] == nil
    end
  end

  describe "Education.csv" do
    test "maps school, degree and folds notes + activities into the description" do
      csv = """
      School Name,Start Date,End Date,Notes,Degree Name,Activities
      MIT,2010,2014,Thesis on bridges,BSc,Robotics club
      """

      {:ok, result} = LinkedIn.parse(zip([{"Education.csv", csv}]))

      assert [edu] = result.educations
      assert edu.params["school"] == "MIT"
      assert edu.params["degree"] == "BSc"
      assert edu.params["start_year"] == 2010
      assert edu.params["end_year"] == 2014
      assert edu.params["description"] =~ "Thesis on bridges"
      assert edu.params["description"] =~ "Robotics club"
    end
  end

  describe "Certifications.csv (issue #859)" do
    test "maps name, authority, dates, licence number and url as a certification" do
      csv = """
      Name,Url,Authority,Started On,Finished On,License Number
      AWS Solutions Architect,https://verify.example.org/a,Amazon Web Services,Jan 2023,Jan 2026,AWS-1234
      """

      {:ok, result} = LinkedIn.parse(zip([{"Certifications.csv", csv}]))

      assert [cert] = result.certifications
      assert cert.params["name"] == "AWS Solutions Architect"
      assert cert.params["kind"] == "certification"
      assert cert.params["issuer"] == "Amazon Web Services"
      assert cert.params["awarded_month"] == 1
      assert cert.params["awarded_year"] == 2023
      assert cert.params["expires_year"] == 2026
      assert cert.params["credential_id"] == "AWS-1234"
      assert cert.params["url"] == "https://verify.example.org/a"
    end

    test "classifies by header even when the file is named oddly" do
      csv =
        "Name,Url,Authority,Started On,Finished On,License Number\nCSM,,Scrum Alliance,2022,,\n"

      {:ok, result} = LinkedIn.parse(zip([{"weird_name.csv", csv}]))

      assert [cert] = result.certifications
      assert cert.params["name"] == "CSM"
    end

    test "a certification row without a name is dropped" do
      csv = "Name,Url,Authority,Started On,Finished On,License Number\n,,Some Authority,2022,,\n"
      {:ok, result} = LinkedIn.parse(zip([{"Certifications.csv", csv}]))

      assert result.certifications == []
    end
  end

  describe "Skills.csv" do
    test "keeps a multi-word skill whole as one tag candidate and dedups" do
      csv = "Name\nElixir\nRuby on Rails\nElixir\n"
      {:ok, result} = LinkedIn.parse(zip([{"Skills.csv", csv}]))

      labels = Enum.map(result.skills, & &1.label)
      # One CSV row is one skill: "Ruby on Rails" stays one candidate now that
      # tags may contain spaces, it is not exploded into "Ruby"/"on"/"Rails".
      assert "Elixir" in labels
      assert "Ruby on Rails" in labels
      refute "Ruby" in labels
      # Elixir appears twice in the file but once in the candidates.
      assert Enum.count(labels, &(&1 == "Elixir")) == 1
    end
  end

  describe "PhoneNumbers.csv" do
    test "maps the number and normalizes the type to the vutuv set" do
      csv = "Extension,Number,Type\n,+49 30 1234567,Mobile\n"
      {:ok, result} = LinkedIn.parse(zip([{"PhoneNumbers.csv", csv}]))

      assert [%{params: %{"value" => "+49 30 1234567", "number_type" => "Cell"}}] = result.phones
    end

    test "maps a fax line to the Fax type (#948)" do
      csv = "Extension,Number,Type\n,+49 30 1234567,Fax\n"
      {:ok, result} = LinkedIn.parse(zip([{"PhoneNumbers.csv", csv}]))

      assert [%{params: %{"value" => "+49 30 1234567", "number_type" => "Fax"}}] = result.phones
    end

    # Real archives list the same number more than once (and in more than one
    # format); the digit-based candidate id collapses them so the preview shows
    # one row, not a run of duplicate checkboxes.
    test "the same number in different formats yields one candidate" do
      csv = "Extension,Number,Type\n,+49 1515 0230373,Mobile\n,4915150230373,Mobile\n"
      {:ok, result} = LinkedIn.parse(zip([{"PhoneNumbers.csv", csv}]))

      assert [%{params: %{"value" => "+49 1515 0230373"}}] = result.phones
    end

    test "rows without a number yield no candidates" do
      csv = "Extension,Number,Type\n,,Mobile\n,,Mobile\n"
      {:ok, result} = LinkedIn.parse(zip([{"PhoneNumbers.csv", csv}]))

      assert result.phones == []
    end
  end

  describe "blank-row hygiene" do
    # A candidate missing its essentials can only fail (or insert an empty row)
    # at apply time and renders an empty preview checkbox until then — drop it
    # at parse.
    test "an education row without a school is dropped" do
      csv = "School Name,Start Date,End Date,Notes,Degree Name,Activities\n,1990,1993,,Abitur,\n"
      {:ok, result} = LinkedIn.parse(zip([{"Education.csv", csv}]))

      assert result.educations == []
    end

    test "a position row without organization or title is dropped" do
      csv = """
      Company Name,Title,Description,Location,Started On,Finished On
      ,Engineer,,Berlin,2020,
      Acme,,,Berlin,2020,
      """

      {:ok, result} = LinkedIn.parse(zip([{"Positions.csv", csv}]))

      assert result.positions == []
    end
  end

  describe "Volunteering.csv" do
    test "maps volunteer roles into position candidates with kind volunteer (issue #840)" do
      csv = """
      Company Name,Role,Cause,Started On,Finished On,Description
      Water Watch,River Guardian,Environment,Feb 2016,Jun 2019,Monthly river cleanups
      """

      {:ok, result} = LinkedIn.parse(zip([{"Volunteering.csv", csv}]))

      assert [vol] = result.positions
      assert vol.params["organization"] == "Water Watch"
      assert vol.params["title"] == "River Guardian"
      assert vol.params["kind"] == "volunteer"
      assert vol.params["start_month"] == 2
      assert vol.params["start_year"] == 2016
      assert vol.params["end_month"] == 6
      assert vol.params["end_year"] == 2019
      # The cause rides along in the description, so it is not lost.
      assert vol.params["description"] =~ "Monthly river cleanups"
      assert vol.params["description"] =~ "Environment"
      # The preview label marks the category.
      assert vol.label =~ "River Guardian @ Water Watch"
    end

    test "volunteer roles append after the paid positions" do
      positions = """
      Company Name,Title,Description,Location,Started On,Finished On
      Acme,Engineer,,Berlin,2020,
      """

      volunteering = """
      Company Name,Role,Cause,Started On,Finished On,Description
      Water Watch,River Guardian,,2016,2019,
      """

      {:ok, result} =
        LinkedIn.parse(zip([{"Volunteering.csv", volunteering}, {"Positions.csv", positions}]))

      assert [%{params: %{"organization" => "Acme"}}, %{params: %{"kind" => "volunteer"}}] =
               result.positions
    end

    test "a volunteer row without organization or role is dropped" do
      csv = """
      Company Name,Role,Cause,Started On,Finished On,Description
      ,River Guardian,,2016,,
      Water Watch,,,2016,,
      """

      {:ok, result} = LinkedIn.parse(zip([{"Volunteering.csv", csv}]))

      assert result.positions == []
    end
  end

  describe "classification and scope" do
    test "classifies by header signature, not filename (localized names)" do
      csv = """
      Company Name,Title,Description,Location,Started On,Finished On
      Acme,Engineer,,Berlin,2020,
      """

      # A German export names the file differently; the English headers still win.
      {:ok, result} = LinkedIn.parse(zip([{"Berufserfahrung.csv", csv}]))
      assert [%{params: %{"organization" => "Acme"}}] = result.positions
    end

    test "ignores Connections.csv entirely" do
      connections = """
      First Name,Last Name,URL,Email Address,Company,Position,Connected On
      Conni,Contact,https://x,conni@example.com,Acme,CEO,01 Jan 2020
      """

      {:ok, result} = LinkedIn.parse(zip([{"Connections.csv", connections}]))

      assert result.positions == []
      assert result.emails == []
      assert result.social == []
    end

    test "missing files simply yield empty lists" do
      {:ok, result} = LinkedIn.parse(zip([{"Profile.csv", profile_csv()}]))

      assert result.positions == []
      assert result.educations == []
      assert result.skills == []
      assert result.phones == []
    end
  end

  describe "non-UTF-8 archives" do
    # LinkedIn writes UTF-8, but a member who opens a CSV in Excel and re-saves
    # it before re-zipping ships Windows-1252/Latin-1 bytes. Those must not
    # survive into the parse result: everything downstream assumes valid UTF-8,
    # and Jason.encode! of the preview payload raises on a stray byte (the
    # import's 500).
    test "a Latin-1 encoded CSV is transcoded to UTF-8" do
      csv =
        :unicode.characters_to_binary(
          "Company Name,Title,Description,Location,Started On,Finished On\n" <>
            "Müller GmbH,Geschäftsführer,,Berlin,2020,\n",
          :utf8,
          :latin1
        )

      {:ok, result} = LinkedIn.parse(zip([{"Positions.csv", csv}]))

      assert [%{params: %{"organization" => "Müller GmbH", "title" => "Geschäftsführer"}}] =
               result.positions

      # The preview payload must be JSON-encodable (raised before the fix).
      assert is_binary(Jason.encode!(LinkedIn.payload_map(result)))
    end
  end

  describe "parse_file/1" do
    test "reads the archive from a file on disk" do
      path =
        Path.join(System.tmp_dir!(), "linkedin_parse_#{System.unique_integer([:positive])}.zip")

      File.write!(path, zip([{"Profile.csv", profile_csv()}]))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, result} = LinkedIn.parse_file(path)
      assert result.profile.first_name == "Stefan"
    end

    test "a non-zip file is an invalid archive" do
      path = Path.join(System.tmp_dir!(), "notzip_#{System.unique_integer([:positive])}.zip")
      File.write!(path, "this is not a zip file")
      on_exit(fn -> File.rm(path) end)

      assert LinkedIn.parse_file(path) == {:error, :invalid_archive}
    end
  end

  describe "zip-bomb defense" do
    test "skips an oversized single entry but still imports the small CSVs" do
      big = :binary.copy(<<0>>, 16_000_000)

      positions =
        "Company Name,Title,Description,Location,Started On,Finished On\nAcme,Engineer,,,2020,\n"

      {:ok, result} =
        LinkedIn.parse(zip([{"Connections.csv", big}, {"Positions.csv", positions}]))

      # The 16 MB entry is over the per-entry cap, so it is never decompressed;
      # the small Positions.csv still imports.
      assert [%{params: %{"organization" => "Acme"}}] = result.positions
    end

    test "refuses an archive whose kept entries exceed the total cap" do
      chunk = :binary.copy(<<0>>, 14_000_000)

      # 3 x 14 MB = 42 MB > the 40 MB total cap (each under the per-entry cap).
      assert {:error, :archive_too_large} =
               LinkedIn.parse(zip([{"a.csv", chunk}, {"b.csv", chunk}, {"c.csv", chunk}]))
    end

    test "refuses an archive with too many entries" do
      files = for i <- 1..2001, do: {"f#{i}.csv", "Name\n"}
      assert {:error, :archive_too_large} = LinkedIn.parse(zip(files))
    end

    # The original finding: a spoofed central-directory header declares a small
    # uncompressed size (so the cheap pre-filter keeps the entry) while the real
    # deflate stream inflates far past the per-entry cap. The unpatched code fed
    # the whole stream to `:zip.unzip` with no output cap and OOMed; now the
    # streaming inflater aborts once the actual output crosses the cap.
    test "rejects a declared-small but actually-huge single entry (spoofed header)" do
      # 16 MB of zeros compresses to a few KB; declared as 5 KB it sails past the
      # declared-size pre-filter, then trips the 15 MB per-entry OUTPUT cap.
      archive = bomb_zip(:binary.copy(<<0>>, 16_000_000), 5_000)

      assert {:error, :archive_too_large} = LinkedIn.parse(archive)
    end

    # Objection 1(a): many central-directory entries whose offsets all point at
    # the SAME deflate stream. Detected as overlapping data regions and rejected
    # BEFORE any inflation, so the shared stream is never inflated N times.
    test "rejects an archive whose entries share one offset, promptly" do
      archive = shared_offset_zip(500)

      {micros, result} = :timer.tc(fn -> LinkedIn.parse(archive) end)

      # Overlapping data regions are not a normal archive: rejected outright,
      # before the shared stream is inflated even once.
      assert {:error, :invalid_archive} = result
      # No gigabytes inflated: rejection is a cheap header/interval check.
      assert micros < 1_000_000
    end

    # The two-entry form of the same defect: entry b's data region is patched to
    # overlap entry a's. A normal archive never overlaps.
    test "rejects an archive with two overlapping data regions" do
      assert {:error, :invalid_archive} = LinkedIn.parse(overlapping_zip())
    end

    # Objection 1(b): a stream can consume far more compressed INPUT (and CPU)
    # than it produces OUTPUT, so the output caps alone don't bound the work. The
    # cumulative-input budget is the primary fix. Caps are overridable so the
    # test stays small; production keeps 15 MB / 40 MB / 40 MB.
    test "rejects when the cumulative compressed input exceeds the input budget" do
      # Two incompressible entries (~1.5 KB each). Their declared sizes are tiny
      # so the per-entry OUTPUT caps never fire; only the cumulative INPUT budget
      # (set here to 2 KB) stops them — the second entry pushes the total over.
      a = :crypto.strong_rand_bytes(1_500)
      b = :crypto.strong_rand_bytes(1_500)
      archive = zip([{"a.csv", a}, {"b.csv", b}])

      assert {:error, :archive_too_large} =
               LinkedIn.parse(archive, max_input_bytes: 2_000)

      # With a budget generous enough for both, the same archive is accepted.
      assert {:ok, _} = LinkedIn.parse(archive, max_input_bytes: 40_000_000)
    end

    # Objection 2: a genuinely corrupt/garbage deflate stream must still
    # terminate with an error (a zlib raise, caught and converted) — never hang.
    test "rejects a corrupt deflate stream instead of hanging" do
      {:ok, {_n, bin}} =
        :zip.create(
          ~c"g.zip",
          [{~c"Positions.csv", :binary.copy("Company Name,Title\nA,B\n", 500)}],
          [:memory]
        )

      {:ok, [_comment, {:zip_file, _name, _info, _cm, offset, _comp}]} = :zip.list_dir(bin)

      <<_::binary-size(^offset), _::binary-size(26), name_len::little-16, extra_len::little-16,
        _::binary>> = bin

      data_start = offset + 30 + name_len + extra_len
      # Overwrite the first deflate byte with an invalid block type (BTYPE = 11,
      # reserved), so the very first inflate step raises `:data_error`.
      <<pre::binary-size(^data_start), _first, post::binary>> = bin
      corrupt = pre <> <<0x07>> <> post

      assert {:error, _} = LinkedIn.parse(corrupt)
    end

    # A large but valid entry (well under the caps) must inflate fully across many
    # `safeInflate` iterations — proving zero-output continuations are drained,
    # not mistaken for corruption (objection 2's availability half).
    test "imports a large valid entry that drains over many inflate iterations" do
      header = "Company Name,Title,Description,Location,Started On,Finished On\n"

      body =
        Enum.map_join(1..40_000, "", fn i -> "Org#{i},Engineer #{i},desc,Berlin,2020,\n" end)

      {:ok, result} = LinkedIn.parse(zip([{"Positions.csv", header <> body}]))

      # The final row (end of a ~1.5 MB stream, many `safeInflate` iterations
      # deep) is present, proving the whole stream drained rather than being cut
      # off early or rejected on a zero-output continuation.
      assert Enum.any?(result.positions, &(&1.params["organization"] == "Org40000"))
      # phash2 candidate ids collide a handful of times across 40k rows, so allow
      # for a few merges rather than asserting an exact count.
      assert length(result.positions) > 39_900
    end
  end

  describe "parse_month_year/1" do
    test "parses the LinkedIn date variants" do
      assert LinkedIn.parse_month_year("Jan 2020") == {1, 2020}
      assert LinkedIn.parse_month_year("January 2020") == {1, 2020}
      assert LinkedIn.parse_month_year("2020") == {nil, 2020}
      assert LinkedIn.parse_month_year("") == {nil, nil}
      assert LinkedIn.parse_month_year(nil) == {nil, nil}
    end
  end
end

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

    test "maps a fax line to Work now that Fax is no longer a vutuv type (#948)" do
      csv = "Extension,Number,Type\n,+49 30 1234567,Fax\n"
      {:ok, result} = LinkedIn.parse(zip([{"PhoneNumbers.csv", csv}]))

      assert [%{params: %{"value" => "+49 30 1234567", "number_type" => "Work"}}] = result.phones
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

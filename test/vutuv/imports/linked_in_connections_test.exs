defmodule Vutuv.Imports.LinkedInConnectionsTest do
  @moduledoc """
  The `Connections.csv` half of the export parser (issue #1476): pure, no Repo,
  and it keeps only the two exact identifiers a match can be made on.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Imports.LinkedIn

  defp zip(files) do
    entries = Enum.map(files, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, {_name, binary}} = :zip.create(~c"export.zip", entries, [:memory])
    binary
  end

  @headers "First Name,Last Name,URL,Email Address,Company,Position,Connected On"

  # What LinkedIn really ships: two note lines and a blank one above the header
  # row. Every row below is quoted the way the export quotes them.
  defp real_export(rows) do
    """
    Notes:
    "When exporting your connection data, you may notice that some of the email addresses are missing. You will only see email addresses for connections who have allowed their connections to see or download their email address using this setting https://www.linkedin.com/psettings/privacy/email. You can learn more here https://www.linkedin.com/help/linkedin/answer/261"

    #{@headers}
    #{rows}
    """
  end

  describe "parse_connections/2" do
    test "reads the rows below LinkedIn's own notes preamble" do
      csv =
        real_export("""
        Conni,Contact,https://www.linkedin.com/in/conni-contact,conni@example.com,Acme GmbH,CEO,01 Jan 2020
        """)

      {:ok, contacts} = LinkedIn.parse_connections(zip([{"Connections.csv", csv}]))

      assert contacts == [%{email: "conni@example.com", linkedin: "conni-contact"}]
    end

    test "reads a file with no preamble at all" do
      csv = """
      #{@headers}
      Conni,Contact,https://www.linkedin.com/in/conni,conni@example.com,Acme,CEO,01 Jan 2020
      """

      {:ok, contacts} = LinkedIn.parse_connections(zip([{"Connections.csv", csv}]))

      assert contacts == [%{email: "conni@example.com", linkedin: "conni"}]
    end

    test "classifies by header signature, so a localized filename still works" do
      csv =
        real_export("""
        Conni,Contact,https://www.linkedin.com/in/conni,conni@example.com,Acme,CEO,01 Jan 2020
        """)

      {:ok, contacts} = LinkedIn.parse_connections(zip([{"Kontakte.csv", csv}]))

      assert [%{email: "conni@example.com"}] = contacts
    end

    test "normalizes the profile URL down to the LinkedIn identifier" do
      csv =
        real_export("""
        A,One,https://www.linkedin.com/in/example,,Acme,CEO,01 Jan 2020
        B,Two,https://linkedin.com/in/Example/,,Acme,CEO,01 Jan 2020
        C,Three,http://de.linkedin.com/in/example?trk=foo,,Acme,CEO,01 Jan 2020
        D,Four,www.linkedin.com/in/example#about,,Acme,CEO,01 Jan 2020
        """)

      {:ok, contacts} = LinkedIn.parse_connections(zip([{"Connections.csv", csv}]))

      # All four spellings name the same profile, so they collapse to one contact.
      assert contacts == [%{email: nil, linkedin: "example"}]
    end

    test "downcases and trims email addresses, and drops ones that are not addresses" do
      csv =
        real_export("""
        A,One,, Conni@Example.COM ,Acme,CEO,01 Jan 2020
        B,Two,,not an address,Acme,CEO,01 Jan 2020
        """)

      {:ok, contacts} = LinkedIn.parse_connections(zip([{"Connections.csv", csv}]))

      assert contacts == [%{email: "conni@example.com", linkedin: nil}]
    end

    test "keeps nothing but the two identifiers — no name, employer or position" do
      csv =
        real_export("""
        Conni,Contact,https://www.linkedin.com/in/conni,conni@example.com,Acme GmbH,CEO,01 Jan 2020
        """)

      {:ok, [contact]} = LinkedIn.parse_connections(zip([{"Connections.csv", csv}]))

      assert Map.keys(contact) == [:email, :linkedin]
    end

    test "drops rows carrying neither an address nor a profile URL" do
      csv =
        real_export("""
        Nameless,Person,,,Acme,CEO,01 Jan 2020
        """)

      assert {:ok, []} = LinkedIn.parse_connections(zip([{"Connections.csv", csv}]))
    end

    test "an archive without a connections file yields no contacts" do
      csv = """
      Company Name,Title,Description,Location,Started On,Finished On
      Acme,Engineer,,Berlin,2020,
      """

      assert {:ok, []} = LinkedIn.parse_connections(zip([{"Positions.csv", csv}]))
    end

    test "anything that is not a readable ZIP is refused" do
      assert {:error, :invalid_archive} = LinkedIn.parse_connections("not a zip")
    end

    test "the profile parse still ignores Connections.csv" do
      csv =
        real_export("""
        Conni,Contact,https://www.linkedin.com/in/conni,conni@example.com,Acme,CEO,01 Jan 2020
        """)

      {:ok, result} = LinkedIn.parse(zip([{"Connections.csv", csv}]))

      assert result.positions == []
      assert result.emails == []
      assert result.social == []
    end
  end
end

defmodule Vutuv.Repo.Migrations.TrimPaddedProfileNames do
  use Ecto.Migration

  # `User.changeset/2` trims these fields now; this cleans the rows saved
  # before it did (on the production copy: 268 first names, 189 last names, 66
  # headlines). A padded name ended up in the vCard and in every mail's To:
  # header. Data only, so it is N-1 safe: the running release reads the same
  # columns. `updated_at` stays as it is, nobody edited these profiles.
  @fields ~w(first_name last_name middle_name nickname honorific_prefix honorific_suffix headline)

  def up do
    sets =
      Enum.map_join(@fields, ",\n", fn field ->
        "#{field} = NULLIF(regexp_replace(#{field}, '^\\s+|\\s+$', '', 'g'), '')"
      end)

    padded = Enum.map_join(@fields, " OR ", &"#{&1} ~ '^\\s|\\s$'")

    execute("UPDATE users SET #{sets} WHERE #{padded}")
  end

  # The padding carried no meaning, so there is nothing to put back.
  def down, do: :ok
end
